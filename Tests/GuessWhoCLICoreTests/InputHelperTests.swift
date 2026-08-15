import Foundation
import MCP
import XCTest
@testable import GuessWhoCLICore

/// The two NEW shared input helpers Phase 3 introduces: `--body` text input and
/// `--json` structured input. Both are pure, so the read/bound/decode logic runs
/// over in-memory handles (a `Pipe` stands in for stdin) with no live app.
final class InputHelperTests: XCTestCase {

    // MARK: - CLITextInput

    func testTextReadInlineReturnsLiteralText() throws {
        XCTAssertEqual(try CLITextInput.read(inline: "First met at the fair.", file: nil),
                       "First met at the fair.")
    }

    func testTextReadFileReturnsFileContents() throws {
        let path = try makeTempFile(Data("From a file.".utf8))
        XCTAssertEqual(try CLITextInput.read(inline: nil, file: path), "From a file.")
    }

    func testTextReadDashReadsStdinViaBoundedRead() throws {
        // The inline `-` marker routes to stdin; a Pipe stands in. A small
        // payload fits the pipe buffer, so write-then-close on this thread cannot
        // deadlock the read.
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("streamed body".utf8))
        try pipe.fileHandleForWriting.close()
        let text = try CLITextInput.readBounded(from: pipe.fileHandleForReading, source: "stdin")
        XCTAssertEqual(text, "streamed body")
        try? pipe.fileHandleForReading.close()
    }

    func testTextBothSourcesIsUsageError() {
        XCTAssertThrowsError(try CLITextInput.read(inline: "x", file: "/tmp/y")) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testTextNeitherSourceIsUsageError() {
        XCTAssertThrowsError(try CLITextInput.read(inline: nil, file: nil)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testTextMissingFileIsUsageError() {
        XCTAssertThrowsError(try CLITextInput.read(inline: nil, file: "/no/such/note.txt")) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testTextOverCapIsUsageError() throws {
        let oversize = Data(repeating: 0x41, count: CLITextInput.maxBodyBytes + 1)
        let path = try makeTempFile(oversize)
        XCTAssertThrowsError(try CLITextInput.read(inline: nil, file: path)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testTextExactlyAtCapReadsWhole() throws {
        let atCap = Data(repeating: 0x41, count: CLITextInput.maxBodyBytes)
        let path = try makeTempFile(atCap)
        let text = try CLITextInput.read(inline: nil, file: path)
        XCTAssertEqual(text.utf8.count, CLITextInput.maxBodyBytes)
    }

    // MARK: - CLIJSONInput

    func testJSONReadInlineDecodesArray() throws {
        let value = try CLIJSONInput.read(inline: "[{\"kind\":\"contact\",\"id\":\"c1\"}]", file: nil)
        XCTAssertEqual(value, .array([.object(["kind": .string("contact"), "id": .string("c1")])]))
    }

    func testJSONReadFileDecodesArray() throws {
        let path = try makeTempFile(Data("[{\"address\":\"1 Main St\"}]".utf8))
        let value = try CLIJSONInput.read(inline: nil, file: path)
        XCTAssertEqual(value, .array([.object(["address": .string("1 Main St")])]))
    }

    func testJSONReadDashDecodesStdinViaBoundedRead() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("[\"g1\",\"g2\"]".utf8))
        try pipe.fileHandleForWriting.close()
        let text = try CLIJSONInput.readBounded(from: pipe.fileHandleForReading, source: "stdin")
        XCTAssertEqual(try CLIJSONInput.decode(text), .array([.string("g1"), .string("g2")]))
        try? pipe.fileHandleForReading.close()
    }

    func testJSONNeitherSourceReturnsNil() throws {
        XCTAssertNil(try CLIJSONInput.read(inline: nil, file: nil))
    }

    func testJSONBothSourcesIsUsageError() {
        XCTAssertThrowsError(try CLIJSONInput.read(inline: "[]", file: "/tmp/x.json")) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testJSONMalformedIsUsageError() {
        XCTAssertThrowsError(try CLIJSONInput.read(inline: "[{not valid", file: nil)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testJSONEmptyInlineIsUsageError() {
        // An empty string is present (not `-`, not omitted), so it is parsed —
        // and the empty document is not valid JSON, so it is a usage error, not
        // a "neither source" nil.
        XCTAssertThrowsError(try CLIJSONInput.read(inline: "", file: nil)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testJSONEmptyStdinIsUsageError() throws {
        // `--json -` with nothing on stdin: the bounded read returns "", which
        // decode rejects as invalid JSON (a usage error), never a crash.
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        let text = try CLIJSONInput.readBounded(from: pipe.fileHandleForReading, source: "stdin")
        XCTAssertEqual(text, "")
        XCTAssertThrowsError(try CLIJSONInput.decode(text)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
        try? pipe.fileHandleForReading.close()
    }

    func testJSONMalformedUTF8IsUsageError() throws {
        // 0xFF is never valid UTF-8; the bounded read maps it to U+FFFD, which
        // is not valid JSON, so decode reports a usage error rather than
        // trapping on a bad-bytes String init.
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data([0xFF, 0xFE, 0xFF]))
        try pipe.fileHandleForWriting.close()
        let text = try CLIJSONInput.readBounded(from: pipe.fileHandleForReading, source: "stdin")
        XCTAssertThrowsError(try CLIJSONInput.decode(text)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
        try? pipe.fileHandleForReading.close()
    }

    func testJSONOverCapIsUsageError() throws {
        // A structurally-valid but oversize payload (one very long JSON string)
        // is rejected on size before it is ever parsed.
        let big = "[\"" + String(repeating: "a", count: CLIJSONInput.maxJSONBytes) + "\"]"
        let path = try makeTempFile(Data(big.utf8))
        XCTAssertThrowsError(try CLIJSONInput.read(inline: nil, file: path)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testJSONAssignPlacesValueUnderKey() throws {
        var bag: [String: Value] = ["name": .string("Coffee Crawl")]
        try CLIJSONInput.assign(.array([.object(["address": .string("1 Main St")])]), toKey: "places", in: &bag)
        XCTAssertEqual(bag["places"], .array([.object(["address": .string("1 Main St")])]))
    }

    /// A key supplied BOTH by a flag (already in the bag) and by `--json` is a
    /// usage error, never a silent merge.
    func testJSONAssignConflictIsUsageError() {
        var bag: [String: Value] = ["places": .array([])]
        XCTAssertThrowsError(try CLIJSONInput.assign(.array([]), toKey: "places", in: &bag)) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    // MARK: - helpers

    private func makeTempFile(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url.path
    }
}
