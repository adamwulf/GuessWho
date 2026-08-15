import ArgumentParser
import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// The typed exit-code mapping (§4) and the shared renderer's own outputs.
final class ExitCodeAndRenderTests: CLICommandTestCase {

    // MARK: Exit-code constants (§4)

    func testExitCodeRawValues() {
        XCTAssertEqual(CLIExitCode.success.rawValue, 0)
        XCTAssertEqual(CLIExitCode.appError.rawValue, 1)
        XCTAssertEqual(CLIExitCode.declinedDelete.rawValue, 10)
        XCTAssertEqual(CLIExitCode.usage.rawValue, 64) // EX_USAGE
        XCTAssertEqual(CLIExitCode.transportUnavailable.rawValue, 69) // EX_UNAVAILABLE
    }

    func testEveryTransportErrorMapsToUnavailable() {
        let errors: [RelayConnectionError] = [
            .hostNotRunning, .hostNotReady, .timedOut,
            .transport(CocoaError(.fileNoSuchFile)),
        ]
        for error in errors {
            XCTAssertEqual(CLIExitCode.code(for: error), .transportUnavailable)
        }
    }

    // MARK: Transport error mapping through the funnel

    func testTransportFailureExits69WithWireMessage() async throws {
        let error = RelayConnectionError.hostNotRunning
        let output = installRuntime(transport: ThrowingCLITransport(error: error))

        let command = try ContactsSearch.parse(["Ada"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.transportUnavailable.rawValue)
        XCTAssertEqual(output.stderr, error.description + "\n")
        XCTAssertTrue(output.stdoutString.isEmpty)
    }

    func testTimeoutFailureExits69() async throws {
        let error = RelayConnectionError.timedOut
        let output = installRuntime(transport: ThrowingCLITransport(error: error))

        let command = try ContactsSearch.parse(["Ada"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.transportUnavailable.rawValue)
        XCTAssertEqual(output.stderr, WireErrorMessage.timedOut + "\n")
    }

    // MARK: The container-resolution failure path

    func testContainerResolutionFailureExits69() async throws {
        let output = CapturingCLIOutput()
        CLIRuntime.current = CLIRuntime(
            containerURL: { throw CLIRuntimeError.notConfigured },
            groupID: { throw CLIRuntimeError.notConfigured },
            makeTransport: { _ in StubCLITransport(response: .ready(helperId: "h", messageId: "m")) },
            output: output)

        let command = try ContactsSearch.parse(["Ada"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.transportUnavailable.rawValue)
        XCTAssertEqual(output.stderr, CLIRuntimeError.notConfigured.description + "\n")
    }

    // MARK: The shared renderer, exercised directly

    func testRendererWritesJSONAndReturnsSuccess() throws {
        let page = WirePage(items: [
            WireContactSummary(id: "c1", kind: "person", name: "Ada", organization: nil, jobTitle: nil),
        ], nextCursor: nil)
        let response = WireResponse.contactPage(helperId: "h", messageId: "m", page: page)
        let output = CapturingCLIOutput()

        let code = CLIResponseRenderer.render(response, to: output)

        XCTAssertEqual(code, .success)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testRendererWritesAckAndReturnsSuccess() {
        let response = WireResponse.acknowledged(helperId: "h", messageId: "m", message: "Done.")
        let output = CapturingCLIOutput()

        let code = CLIResponseRenderer.render(response, to: output)

        XCTAssertEqual(code, .success)
        XCTAssertEqual(output.stdoutString, "Done.\n")
    }

    func testRendererRoutesErrorToStderrAndReturnsAppError() {
        let response = WireResponse.error(
            helperId: "h", messageId: "m", code: .readOnly, message: WireErrorMessage.readOnly)
        let output = CapturingCLIOutput()

        let code = CLIResponseRenderer.render(response, to: output)

        XCTAssertEqual(code, .appError)
        XCTAssertTrue(output.stdoutString.isEmpty)
        XCTAssertEqual(output.stderr, WireErrorMessage.readOnly + "\n")
    }

    /// The error branch prints the plain message ONLY — never the typed code
    /// name (matches BannedVocabularyTests.testErrorCodeNamesStayOutOfAgentText).
    func testRendererNeverPrintsErrorCodeName() {
        let response = WireResponse.error(
            helperId: "h", messageId: "m", code: .notFound, message: WireErrorMessage.notFoundContact)
        let output = CapturingCLIOutput()
        _ = CLIResponseRenderer.render(response, to: output)
        XCTAssertFalse(output.stderr.contains("notFound"))
    }
}
