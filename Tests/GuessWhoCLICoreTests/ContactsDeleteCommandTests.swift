import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the confirmation-gated `contacts delete`, plus its
/// bespoke render: the DELETED ack to stdout (exit 0), the DECLINED ack to
/// stderr (exit 10, stdout empty), a typed error to stderr (exit 1), and the
/// stderr-only wait note.
final class ContactsDeleteCommandTests: CLICommandTestCase {

    // MARK: Parse

    func testParsesContactIdAndIdempotencyToken() throws {
        let command = try ContactsDelete.parse(["c1", "--idempotency-token", "tok"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.idempotencyToken, "tok")
    }

    func testParsesWithoutIdempotencyToken() throws {
        let command = try ContactsDelete.parse(["c1"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertNil(command.idempotencyToken)
    }

    func testMissingContactIdIsParseError() {
        XCTAssertThrowsError(try ContactsDelete.parse([]))
    }

    // MARK: Request build

    func testBuildsExpectedRequestWithToken() throws {
        let command = try ContactsDelete.parse(["c1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsDelete.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsDelete(
            helperId: "cli-test", messageId: "m1", contactId: "c1", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testBuildsExpectedRequestWithoutToken() throws {
        let command = try ContactsDelete.parse(["c1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsDelete.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsDelete(
            helperId: "cli-test", messageId: "m1", contactId: "c1", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    /// The tool's 300 s timeout comes for free from the shared funnel, giving
    /// the human time to answer the in-app dialog.
    func testUsesTheToolsThreeHundredSecondTimeout() async throws {
        let transport = RecordingCLITransport(response: .acknowledged(
            helperId: "h", messageId: "m", message: WireAckMessage.contactDeleted))
        installRuntime(transport: transport)

        let command = try ContactsDelete.parse(["c1"])
        _ = await exitCode { try await command.run() }

        XCTAssertEqual(transport.timeout, 300)
        XCTAssertEqual(MCPTool.contactsDelete.timeout, 300)
    }

    // MARK: Render — DELETED ack

    func testDeletedAckGoesToStdoutWithExitZero() async throws {
        let response = WireResponse.acknowledged(
            helperId: "h", messageId: "m", message: WireAckMessage.contactDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsDelete.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code) // success
        XCTAssertEqual(output.stdoutString, WireAckMessage.contactDeleted + "\n")
    }

    // MARK: Render — DECLINED ack

    func testDeclinedAckGoesToStderrWithExitTenAndEmptyStdout() async throws {
        let response = WireResponse.acknowledged(
            helperId: "h", messageId: "m", message: WireAckMessage.contactDeleteDeclined)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsDelete.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.declinedDelete.rawValue)
        XCTAssertEqual(code, 10)
        XCTAssertTrue(output.stdoutString.isEmpty, "declined must not write to stdout")
        XCTAssertTrue(
            output.stderr.contains(WireAckMessage.contactDeleteDeclined),
            "declined message must be on stderr")
    }

    // MARK: Render — typed error

    func testRequiresAppActionErrorGoesToStderrWithExitOne() async throws {
        let response = WireResponse.error(
            helperId: "h", messageId: "m",
            code: .requiresAppAction, message: WireErrorMessage.confirmationUnavailable)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsDelete.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.appError.rawValue)
        XCTAssertEqual(code, 1)
        XCTAssertTrue(output.stdoutString.isEmpty, "an error must not write to stdout")
        XCTAssertTrue(output.stderr.contains(WireErrorMessage.confirmationUnavailable))
        // The typed code name is never printed.
        XCTAssertFalse(output.stderr.contains("requiresAppAction"))
    }

    // MARK: Wait note

    /// The wait note is written to stderr and NEVER to stdout. On the DELETED
    /// path stdout carries only the ack line; stderr carries only the note.
    func testWaitNoteGoesToStderrNeverStdout() async throws {
        let response = WireResponse.acknowledged(
            helperId: "h", messageId: "m", message: WireAckMessage.contactDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsDelete.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        let note = try XCTUnwrap(command.preSendNote)
        XCTAssertTrue(output.stderr.contains(note), "the wait note must be on stderr")
        XCTAssertFalse(output.stdoutString.contains(note), "the wait note must never reach stdout")
        XCTAssertEqual(output.stdoutString, WireAckMessage.contactDeleted + "\n")
        XCTAssertEqual(output.stderr, note + "\n")
    }
}
