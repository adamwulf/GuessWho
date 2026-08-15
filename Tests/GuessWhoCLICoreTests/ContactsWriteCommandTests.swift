import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the Phase 3 contacts writes (notes, custom fields,
/// favorite), and render for the note echo, custom-field echo, and the fixed
/// ack shapes.
final class ContactsWriteCommandTests: CLICommandTestCase {

    // MARK: contacts add-note — parse + request build

    func testAddNoteParsesIdAndBody() throws {
        let command = try ContactsAddNote.parse(["c1", "--body", "First met at the fair."])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.body, "First met at the fair.")
        XCTAssertNil(command.bodyFile)
        XCTAssertNil(command.idempotencyToken)
    }

    func testAddNoteParsesBodyDashAndFile() throws {
        XCTAssertEqual(try ContactsAddNote.parse(["c1", "--body", "-"]).body, "-")
        XCTAssertEqual(try ContactsAddNote.parse(["c1", "--body-file", "/tmp/n.txt"]).bodyFile, "/tmp/n.txt")
    }

    func testAddNoteBuildsExpectedRequest() throws {
        let command = try ContactsAddNote.parse(["c1", "--body", "Hello", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsAddNote.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsAddNote(
            helperId: "cli-test", messageId: "m1", contactId: "c1", body: "Hello", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testAddNoteMissingBodyIsUsageError() throws {
        let command = try ContactsAddNote.parse(["c1"])
        XCTAssertThrowsError(try command.argumentBag()) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    // MARK: contacts edit-note — parse + request build

    func testEditNoteParsesIdsAndBody() throws {
        let command = try ContactsEditNote.parse(["c1", "n1", "--body", "Updated."])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.noteId, "n1")
        XCTAssertEqual(command.body, "Updated.")
    }

    func testEditNoteBuildsExpectedRequest() throws {
        let command = try ContactsEditNote.parse(["c1", "n1", "--body", "Updated."])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsEditNote.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsEditNote(
            helperId: "cli-test", messageId: "m1", contactId: "c1", noteId: "n1",
            body: "Updated.", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts delete-note — parse + request build

    func testDeleteNoteParsesIds() throws {
        let command = try ContactsDeleteNote.parse(["c1", "n1"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.noteId, "n1")
    }

    func testDeleteNoteBuildsExpectedRequest() throws {
        let command = try ContactsDeleteNote.parse(["c1", "n1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsDeleteNote.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsDeleteNote(
            helperId: "cli-test", messageId: "m1", contactId: "c1", noteId: "n1", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts set-custom-field — parse + request build

    func testSetCustomFieldParsesPositionalsAndType() throws {
        let command = try ContactsSetCustomField.parse(["c1", "Coffee order", "Flat white", "--type", "text"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.name, "Coffee order")
        XCTAssertEqual(command.value, "Flat white")
        XCTAssertEqual(command.type, .text)
    }

    func testSetCustomFieldRejectsUnknownType() {
        XCTAssertThrowsError(try ContactsSetCustomField.parse(["c1", "n", "v", "--type", "bogus"]))
    }

    func testSetCustomFieldBuildsExpectedRequestWithType() throws {
        let command = try ContactsSetCustomField.parse([
            "c1", "Anniversary", "2026-06-01", "--type", "date", "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSetCustomField.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsSetCustomField(
            helperId: "cli-test", messageId: "m1", contactId: "c1", name: "Anniversary",
            type: "date", value: "2026-06-01", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testSetCustomFieldBuildsExpectedRequestWithoutType() throws {
        let command = try ContactsSetCustomField.parse(["c1", "Coffee order", "Flat white"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSetCustomField.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsSetCustomField(
            helperId: "cli-test", messageId: "m1", contactId: "c1", name: "Coffee order",
            type: nil, value: "Flat white", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts delete-custom-field — parse + request build

    func testDeleteCustomFieldBuildsExpectedRequest() throws {
        let command = try ContactsDeleteCustomField.parse(["c1", "f1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsDeleteCustomField.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsDeleteCustomField(
            helperId: "cli-test", messageId: "m1", contactId: "c1", fieldId: "f1", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts set-favorite — parse + request build (flag required)

    func testSetFavoriteParsesFlagBothWays() throws {
        XCTAssertEqual(try ContactsSetFavorite.parse(["c1", "--favorite"]).favorite, true)
        XCTAssertEqual(try ContactsSetFavorite.parse(["c1", "--no-favorite"]).favorite, false)
        XCTAssertNil(try ContactsSetFavorite.parse(["c1"]).favorite)
    }

    func testSetFavoriteMissingFlagIsUsageError() throws {
        let command = try ContactsSetFavorite.parse(["c1"])
        XCTAssertThrowsError(try command.argumentBag()) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testSetFavoriteBuildsExpectedRequestWhenTrue() throws {
        let command = try ContactsSetFavorite.parse(["c1", "--favorite", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSetFavorite.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsSetFavorite(
            helperId: "cli-test", messageId: "m1", contactId: "c1", favorite: true, idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testSetFavoriteBuildsExpectedRequestWhenFalse() throws {
        let command = try ContactsSetFavorite.parse(["c1", "--no-favorite"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSetFavorite.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsSetFavorite(
            helperId: "cli-test", messageId: "m1", contactId: "c1", favorite: false, idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — note echo

    func testAddNoteRendersNoteEchoAsJSON() async throws {
        let note = WireNote(id: "n1", body: "Hello", createdAt: "2026-01-02T00:00:00Z", modifiedAt: "2026-01-02T00:00:00Z")
        let response = WireResponse.note(helperId: "h", messageId: "m", note: note)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsAddNote.parse(["c1", "--body", "Hello"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(note) + "\n")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    // MARK: Render — custom-field echo

    func testSetCustomFieldRendersFieldEchoAsJSON() async throws {
        let field = WireCustomField(id: "f1", name: "Coffee order", type: "text",
                                    value: "Flat white", modifiedAt: "2026-01-02T00:00:00Z")
        let response = WireResponse.customField(helperId: "h", messageId: "m", field: field)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsSetCustomField.parse(["c1", "Coffee order", "Flat white"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(field) + "\n")
    }

    // MARK: Render — fixed acks

    func testDeleteNoteRendersAck() async throws {
        let response = ack(WireAckMessage.noteDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try ContactsDeleteNote.parse(["c1", "n1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.noteDeleted + "\n")
    }

    func testDeleteCustomFieldRendersAck() async throws {
        let response = ack(WireAckMessage.fieldDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try ContactsDeleteCustomField.parse(["c1", "f1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.fieldDeleted + "\n")
    }

    func testSetFavoriteRendersAck() async throws {
        let response = ack(WireAckMessage.favoriteSet)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try ContactsSetFavorite.parse(["c1", "--favorite"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.favoriteSet + "\n")
    }

    // MARK: helpers

    private func ack(_ message: String) -> WireResponse {
        .acknowledged(helperId: "h", messageId: "m", message: message)
    }
}
