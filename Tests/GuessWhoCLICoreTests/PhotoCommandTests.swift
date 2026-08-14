import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// The photo byte path: CLIPhotoInput bounds/sniff, CLIPhotoOutput integrity,
/// and the two photo commands' parse / request-build / render.
final class PhotoCommandTests: XCTestCase {

    private let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // MARK: CLIPhotoInput — bounds

    func testReadBoundedReturnsSmallInputWhole() throws {
        let path = try makeTempFile(pngHeader)
        let data = try CLIPhotoInput.read(path: path)
        XCTAssertEqual(data, pngHeader)
    }

    func testReadBoundedStopsOneByteOverTheCap() throws {
        let cap = WireEnvironment.maxContactPhotoBytes
        let oversize = Data(repeating: 0x41, count: cap + 100)
        let path = try makeTempFile(oversize)
        let data = try CLIPhotoInput.read(path: path)
        // Reads at most cap + 1, so the caller can tell "over the cap" apart
        // from "exactly the cap".
        XCTAssertEqual(data.count, cap + 1)
    }

    func testReadFromMissingFileThrowsUsageError() {
        XCTAssertThrowsError(try CLIPhotoInput.read(path: "/no/such/file.png")) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    // MARK: CLIPhotoInput — media sniff (via set-photo argumentBag)

    func testSetPhotoRejectsEmptyInput() async throws {
        let path = try makeTempFile(Data())
        let output = installRuntime(transport: StubCLITransport(response: ack("photoSet")))
        let command = try ContactsSetPhoto.parse(["c1", "-i", path])
        let code = await exitCode { try await command.run() }
        XCTAssertEqual(code, CLIExitCode.usage.rawValue)
        XCTAssertEqual(output.stderr, "The input image is empty.\n")
    }

    func testSetPhotoRejectsOversizeInput() async throws {
        let path = try makeTempFile(Data(repeating: 0x41, count: WireEnvironment.maxContactPhotoBytes + 1))
        let output = installRuntime(transport: StubCLITransport(response: ack("photoSet")))
        let command = try ContactsSetPhoto.parse(["c1", "-i", path])
        let code = await exitCode { try await command.run() }
        XCTAssertEqual(code, CLIExitCode.usage.rawValue)
        XCTAssertEqual(output.stderr, "The input image is larger than 180 KiB.\n")
    }

    func testSetPhotoRejectsNonImageInput() async throws {
        let path = try makeTempFile(Data("not an image".utf8))
        let output = installRuntime(transport: StubCLITransport(response: ack("photoSet")))
        let command = try ContactsSetPhoto.parse(["c1", "-i", path])
        let code = await exitCode { try await command.run() }
        XCTAssertEqual(code, CLIExitCode.usage.rawValue)
        XCTAssertEqual(output.stderr, "The input must be a JPEG, PNG, GIF, HEIC, or WebP image.\n")
    }

    // MARK: CLIPhotoOutput — integrity

    func testDecodeThrowsWhenNotPresent() {
        let photo = WireContactPhoto.none
        XCTAssertThrowsError(try CLIPhotoOutput.decode(photo)) { error in
            XCTAssertEqual(error as? CLIPhotoOutput.Failure, .notPresent)
        }
    }

    func testDecodeThrowsOnBadBase64() {
        let photo = WireContactPhoto(present: true, mediaType: "image/png", dataBase64: "@@@not base64@@@", byteCount: 8)
        XCTAssertThrowsError(try CLIPhotoOutput.decode(photo)) { error in
            XCTAssertEqual(error as? CLIPhotoOutput.Failure, .invalidData)
        }
    }

    func testDecodeThrowsOnByteCountMismatch() {
        let photo = WireContactPhoto(
            present: true, mediaType: "image/png",
            dataBase64: pngHeader.base64EncodedString(), byteCount: 999)
        XCTAssertThrowsError(try CLIPhotoOutput.decode(photo)) { error in
            XCTAssertEqual(error as? CLIPhotoOutput.Failure, .invalidData)
        }
    }

    func testDecodeReturnsBytesWhenValid() throws {
        let photo = WireContactPhoto(
            present: true, mediaType: "image/png",
            dataBase64: pngHeader.base64EncodedString(), byteCount: pngHeader.count)
        XCTAssertEqual(try CLIPhotoOutput.decode(photo), pngHeader)
    }

    func testWriteToStdoutSinkEmitsRawBytesWithNoNewline() throws {
        let sink = CapturingCLIOutput()
        try CLIPhotoOutput.write(pngHeader, toPath: nil, sink: sink)
        XCTAssertEqual(sink.stdoutData, pngHeader)
    }

    func testWriteToFileWritesBytes() throws {
        let sink = CapturingCLIOutput()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try CLIPhotoOutput.write(pngHeader, toPath: url.path, sink: sink)
        XCTAssertEqual(try Data(contentsOf: url), pngHeader)
        XCTAssertTrue(sink.stdoutData.isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: get-photo — parse & funnel

    func testGetPhotoParsesOutputFlag() throws {
        XCTAssertEqual(try ContactsGetPhoto.parse(["c1"]).output, nil)
        XCTAssertEqual(try ContactsGetPhoto.parse(["c1", "-o", "/tmp/x"]).output, "/tmp/x")
        XCTAssertEqual(try ContactsGetPhoto.parse(["c1", "--output", "/tmp/x"]).output, "/tmp/x")
    }

    func testGetPhotoBuildsExpectedRequest() throws {
        let command = try ContactsGetPhoto.parse(["c1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsGetPhoto.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsGetPhoto(helperId: "cli-test", messageId: "m1", contactId: "c1")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testGetPhotoWritesBytesToFile() async throws {
        let photo = WireContactPhoto(
            present: true, mediaType: "image/png",
            dataBase64: pngHeader.base64EncodedString(), byteCount: pngHeader.count)
        let response = WireResponse.contactPhoto(helperId: "h", messageId: "m", photo: photo)
        installRuntime(transport: StubCLITransport(response: response))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let command = try ContactsGetPhoto.parse(["c1", "-o", url.path])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(try Data(contentsOf: url), pngHeader)
        try? FileManager.default.removeItem(at: url)
    }

    func testGetPhotoWritesBytesToStdout() async throws {
        let photo = WireContactPhoto(
            present: true, mediaType: "image/png",
            dataBase64: pngHeader.base64EncodedString(), byteCount: pngHeader.count)
        let response = WireResponse.contactPhoto(helperId: "h", messageId: "m", photo: photo)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsGetPhoto.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutData, pngHeader)
    }

    func testGetPhotoNoPhotoExitsAppErrorToStderr() async throws {
        let response = WireResponse.contactPhoto(helperId: "h", messageId: "m", photo: .none)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsGetPhoto.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.appError.rawValue)
        XCTAssertEqual(output.stderr, "That contact does not have a photo.\n")
        XCTAssertTrue(output.stdoutData.isEmpty)
    }

    func testGetPhotoTypedErrorExitsAppErrorToStderr() async throws {
        let response = WireResponse.error(
            helperId: "h", messageId: "m", code: .notFound,
            message: WireErrorMessage.notFoundContact)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsGetPhoto.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.appError.rawValue)
        XCTAssertEqual(output.stderr, WireErrorMessage.notFoundContact + "\n")
    }

    // MARK: set-photo — parse, request-build, render

    func testSetPhotoParsesFlags() throws {
        let command = try ContactsSetPhoto.parse(["c1", "-i", "/tmp/x", "--idempotency-token", "tok"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.input, "/tmp/x")
        XCTAssertEqual(command.idempotencyToken, "tok")
    }

    func testSetPhotoBuildsExpectedRequest() async throws {
        let path = try makeTempFile(pngHeader)
        let command = try ContactsSetPhoto.parse(["c1", "-i", path, "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSetPhoto.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsSetPhoto(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            mediaType: "image/png", dataBase64: pngHeader.base64EncodedString(),
            idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testSetPhotoRendersAckToStdout() async throws {
        let path = try makeTempFile(pngHeader)
        let output = installRuntime(transport: StubCLITransport(response: ack("The photo was set.")))
        let command = try ContactsSetPhoto.parse(["c1", "-i", path])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, "The photo was set.\n")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    // MARK: helpers

    private func makeTempFile(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url.path
    }

    private func ack(_ message: String) -> WireResponse {
        .acknowledged(helperId: "h", messageId: "m", message: message)
    }
}
