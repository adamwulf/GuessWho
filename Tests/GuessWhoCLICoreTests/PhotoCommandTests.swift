import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// The photo byte path: CLIPhotoInput bounds/sniff, CLIPhotoOutput integrity,
/// and the two photo commands' parse / request-build / render.
final class PhotoCommandTests: CLICommandTestCase {

    private let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // MARK: CLIPhotoInput — bounds
    //
    // stdin is the only source in production; `readBounded(from:)` is driven
    // here over a seekable temp-file handle (sized cases) and a Pipe (the
    // streaming case), which is exactly the handle shape stdin presents.

    func testReadBoundedReturnsSmallInputWhole() throws {
        let data = try CLIPhotoInput.readBounded(from: try handle(over: pngHeader), source: "stdin")
        XCTAssertEqual(data, pngHeader)
    }

    func testReadBoundedStopsOneByteOverTheCap() throws {
        let cap = WireEnvironment.maxContactPhotoBytes
        let oversize = Data(repeating: 0x41, count: cap + 100)
        let data = try CLIPhotoInput.readBounded(from: try handle(over: oversize), source: "stdin")
        // Reads at most cap + 1, so the caller can tell "over the cap" apart
        // from "exactly the cap".
        XCTAssertEqual(data.count, cap + 1)
    }

    func testReadBoundedReturnsExactlyCapWhole() throws {
        let cap = WireEnvironment.maxContactPhotoBytes
        let atCap = Data(repeating: 0x41, count: cap)
        let data = try CLIPhotoInput.readBounded(from: try handle(over: atCap), source: "stdin")
        // Exactly the cap reads back whole (cap bytes, NOT cap + 1): the wire
        // limit is `<= maxContactPhotoBytes`, so the boundary value is accepted.
        XCTAssertEqual(data.count, cap)
    }

    func testReadBoundedReadsWholeInputFromStreamingHandle() throws {
        // stdin is a streaming, non-seekable FileHandle; a Pipe stands in. A
        // small payload fits the pipe buffer, so writing then closing on this
        // thread cannot deadlock the read.
        let pipe = Pipe()
        let payload = Data(repeating: 0x42, count: 4_096)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()
        let data = try CLIPhotoInput.readBounded(from: pipe.fileHandleForReading, source: "stdin")
        XCTAssertEqual(data, payload)
        try? pipe.fileHandleForReading.close()
    }

    // MARK: set-photo — media sniff + validation (photoArgumentBag)

    func testSetPhotoAcceptsInputExactlyAtCap() throws {
        // A PNG-headed blob of exactly the cap: the media sniff reads the
        // header and `data.count == cap` is within the `<= cap` limit, so the
        // bag is built — no rejection.
        let cap = WireEnvironment.maxContactPhotoBytes
        var atCap = pngHeader
        atCap.append(Data(repeating: 0x00, count: cap - pngHeader.count))
        let command = try ContactsSetPhoto.parse(["c1"])
        let bag = try command.photoArgumentBag(from: atCap)
        XCTAssertEqual(bag["mediaType"], .string("image/png"))
        XCTAssertEqual(bag["dataBase64"], .string(atCap.base64EncodedString()))
    }

    func testSetPhotoRejectsEmptyInput() throws {
        let command = try ContactsSetPhoto.parse(["c1"])
        XCTAssertThrowsError(try command.photoArgumentBag(from: Data())) { error in
            XCTAssertEqual((error as? CLIUsageError)?.message, "The input image is empty.")
        }
    }

    func testSetPhotoRejectsOversizeInput() throws {
        let oversize = Data(repeating: 0x41, count: WireEnvironment.maxContactPhotoBytes + 1)
        let command = try ContactsSetPhoto.parse(["c1"])
        XCTAssertThrowsError(try command.photoArgumentBag(from: oversize)) { error in
            XCTAssertEqual((error as? CLIUsageError)?.message, "The input image is larger than 180 KiB.")
        }
    }

    func testSetPhotoRejectsNonImageInput() throws {
        let command = try ContactsSetPhoto.parse(["c1"])
        XCTAssertThrowsError(try command.photoArgumentBag(from: Data("not an image".utf8))) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "The input must be a JPEG, PNG, GIF, HEIC, or WebP image.")
        }
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

    // MARK: set-photo — parse, request-build

    func testSetPhotoParsesContactAndToken() throws {
        let command = try ContactsSetPhoto.parse(["c1", "--idempotency-token", "tok"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.idempotencyToken, "tok")
    }

    func testSetPhotoBuildsExpectedRequest() throws {
        let command = try ContactsSetPhoto.parse(["c1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSetPhoto.rawValue,
                arguments: command.photoArgumentBag(from: pngHeader)))
        let expected = WireRequest.contactsSetPhoto(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            mediaType: "image/png", dataBase64: pngHeader.base64EncodedString(),
            idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: helpers

    /// A readable FileHandle over `data` (a temp file), the seekable-handle
    /// shape `readBounded` sees when stdin is redirected from a file.
    private func handle(over data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        addTeardownBlock { try? handle.close() }
        return handle
    }
}
