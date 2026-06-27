import XCTest
import Logging
@testable import GuessWhoLogging

final class GuessWhoLoggingTests: XCTestCase {

    // A unique temp base dir per test, cleaned up in tearDown.
    private var tempBase: URL!

    override func setUpWithError() throws {
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuessWhoLoggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempBase { try? FileManager.default.removeItem(at: tempBase) }
        tempBase = nil
    }

    private func makeLogsDir() throws -> URL {
        let dir = tempBase.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Logfmt formatting / quoting

    func testFormatLeadingFieldsAndStableOrder() {
        // A fixed timestamp so the assertion is deterministic.
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let line = LogfmtLogHandler.format(
            timestamp: date,
            level: .info,
            label: "app.linkedin-handoff",
            message: "hello",
            metadata: [:]
        )
        // Leading fields, in order.
        XCTAssertTrue(line.hasPrefix("ts="), "line should lead with ts=")
        XCTAssertTrue(line.contains(" level=info "), "level should follow ts: \(line)")
        XCTAssertTrue(line.contains(" label=app.linkedin-handoff "), "label should follow level: \(line)")
        XCTAssertTrue(line.contains("msg=hello"), "msg should be present: \(line)")
        // ts value is ISO-8601 UTC with fractional seconds.
        XCTAssertTrue(line.contains("2023-11-14T22:13:20.000Z"), "ts should be ISO-8601 UTC ms: \(line)")
    }

    func testQuotingMessageWithSpaceAndQuote() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // Message contains both a space AND a double-quote — must be quoted and
        // the inner quote backslash-escaped.
        let line = LogfmtLogHandler.format(
            timestamp: date,
            level: .error,
            label: "test",
            message: "he said \"hi there\"",
            metadata: [:]
        )
        // String.logfmt wraps a value containing a space/quote in quotes and
        // backslash-escapes the inner quote: msg="he said \"hi there\""
        XCTAssertTrue(
            line.contains(#"msg="he said \"hi there\"""#),
            "message with space+quote should be quoted and escaped: \(line)"
        )
    }

    func testEmbeddedNewlineProducesSingleLine() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let line = LogfmtLogHandler.format(
            timestamp: date,
            level: .error,
            label: "test",
            message: "first line\nsecond line\r\nthird",
            metadata: ["detail": .string("a\nb")]
        )
        XCTAssertFalse(line.contains("\n"), "no LF allowed in a record: \(line)")
        XCTAssertFalse(line.contains("\r"), "no CR allowed in a record: \(line)")
        // The newline becomes a space, so the message is still quoted (it now
        // contains spaces) and remains one line.
        XCTAssertTrue(line.contains("msg="), "msg should still be emitted: \(line)")
    }

    func testMetadataIsFlattenedAndDotNested() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let line = LogfmtLogHandler.format(
            timestamp: date,
            level: .info,
            label: "test",
            message: "m",
            metadata: ["nested": .dictionary(["k": .string("v")]), "count": .stringConvertible(42)]
        )
        XCTAssertTrue(line.contains("nested.k=v"), "nested dict should dot-flatten: \(line)")
        XCTAssertTrue(line.contains("count=42"), "stringConvertible should render: \(line)")
    }

    // MARK: - Rotation

    func testRotationAtTenMegabytes() throws {
        let dir = try makeLogsDir()
        let writer = LogFileWriter(directory: dir, processName: "app")

        // Each line is ~1 KB; write enough to cross 10 MB and trigger a roll.
        let chunk = String(repeating: "x", count: 1024)
        // 11 MB worth of lines guarantees at least one rotation.
        for _ in 0..<(11 * 1024) {
            writer.write(chunk)
        }
        writer.flush()

        let rotated = dir.appendingPathComponent("app-1.log")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "app-1.log should exist after crossing 10 MB"
        )

        // The active file should be under the cap again after the roll.
        let active = dir.appendingPathComponent("app.log")
        let activeSize = (try FileManager.default.attributesOfItem(atPath: active.path)[.size] as? NSNumber)?.uint64Value ?? 0
        XCTAssertLessThan(activeSize, 10 * 1024 * 1024, "active file should be below the cap after rotation")
    }

    func testRotationCapKeepsLimitedSiblings() throws {
        let dir = try makeLogsDir()
        let writer = LogFileWriter(directory: dir, processName: "app")
        let chunk = String(repeating: "y", count: 1024)
        // Write ~70 MB to force several rotations (>5).
        for _ in 0..<(70 * 1024) {
            writer.write(chunk)
        }
        writer.flush()

        // Never more than the cap (5) of rotated siblings.
        let fm = FileManager.default
        let logs = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("app-") && $0.hasSuffix(".log") }
        XCTAssertLessThanOrEqual(logs.count, 5, "rotated siblings should be capped at 5, got \(logs)")
        // The oldest index beyond the cap must not exist.
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("app-6.log").path))
    }

    // MARK: - Prune

    func testPruneDeletesOldFilesKeepsFresh() throws {
        let dir = try makeLogsDir()
        let fm = FileManager.default

        // An old file (mtime 8 days ago) and a fresh one.
        let oldURL = dir.appendingPathComponent("extension-1.log")
        let freshURL = dir.appendingPathComponent("extension-2.log")
        fm.createFile(atPath: oldURL.path, contents: Data("old".utf8))
        fm.createFile(atPath: freshURL.path, contents: Data("fresh".utf8))

        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try fm.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: oldURL.path)

        // Constructing a writer runs a forced prune on init.
        let writer = LogFileWriter(directory: dir, processName: "app")
        writer.flush()

        XCTAssertFalse(fm.fileExists(atPath: oldURL.path), "file older than 7 days should be pruned")
        XCTAssertTrue(fm.fileExists(atPath: freshURL.path), "fresh file should survive prune")
    }

    // MARK: - Graceful degradation on a bad directory

    func testWriteToUnwritableDirectoryDoesNotCrash() throws {
        // Point at a path under a file (not a directory) so opens fail.
        let bogusParent = tempBase.appendingPathComponent("not-a-dir")
        FileManager.default.createFile(atPath: bogusParent.path, contents: Data("x".utf8))
        let badDir = bogusParent.appendingPathComponent("Logs", isDirectory: true)

        let writer = LogFileWriter(directory: badDir, processName: "app")
        writer.write("this should not crash")
        writer.flush()
        // Reaching here without a crash/throw is the assertion.
        XCTAssertTrue(true)
    }

    // MARK: - Double / concurrent bootstrap

    func testDoubleBootstrapDoesNotTrap() {
        // First call installs; second is a no-op. Must not trap.
        GuessWhoLog.bootstrap(processName: "app", appGroupID: "test.group", baseOverride: tempBase)
        GuessWhoLog.bootstrap(processName: "app", appGroupID: "test.group", baseOverride: tempBase)
        // A logger is obtainable.
        let logger = GuessWhoLog.logger("test")
        logger.info("after double bootstrap")
        XCTAssertTrue(true)
    }

    func testConcurrentBootstrapDoesNotTrap() {
        // Many threads racing bootstrap must not double-call LoggingSystem.bootstrap.
        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                GuessWhoLog.bootstrap(processName: "app", appGroupID: "test.group", baseOverride: self.tempBase)
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "concurrent bootstrap should complete without trapping")
    }

    // MARK: - Exporter

    func testExporterProducesValidZipReadableAfterCoordinate() throws {
        let dir = try makeLogsDir()
        let fm = FileManager.default
        fm.createFile(atPath: dir.appendingPathComponent("app.log").path, contents: Data("app log line\n".utf8))
        fm.createFile(atPath: dir.appendingPathComponent("extension.log").path, contents: Data("ext log line\n".utf8))

        let zipURL = try LogExporter.exportLogs(
            appGroupID: "test.group",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            directoryOverride: dir
        )

        // The returned URL is still readable AFTER the coordinate call returned
        // (this catches the unlink-after-block bug, S1).
        XCTAssertTrue(fm.fileExists(atPath: zipURL.path), "exported zip should still exist after coordinate returns")

        let data = try Data(contentsOf: zipURL)
        XCTAssertGreaterThan(data.count, 0, "zip should be non-empty")
        // Valid zip header: PK\x03\x04.
        let header: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        XCTAssertEqual(Array(data.prefix(4)), header, "zip should start with the PK\\x03\\x04 header")

        // Filename shape.
        XCTAssertTrue(zipURL.lastPathComponent.hasPrefix("GuessWho-Logs-"), "zip filename should be GuessWho-Logs-<ts>.zip: \(zipURL.lastPathComponent)")
        XCTAssertEqual(zipURL.pathExtension, "zip")

        try? fm.removeItem(at: zipURL)
    }

    // MARK: - End-to-end through swift-log handler

    func testWriterAppendsThroughHandler() throws {
        let dir = try makeLogsDir()
        let writer = LogFileWriter(directory: dir, processName: "app")
        let handler = LogfmtLogHandler(label: "app.test", writer: writer)
        var logger = Logger(label: "app.test", factory: { _ in handler })
        logger.logLevel = .trace
        logger.notice("a notice message")
        logger.error("boom", metadata: ["code": .stringConvertible(7)])
        writer.flush()

        let contents = try String(contentsOf: dir.appendingPathComponent("app.log"), encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "two records → two lines: \(contents)")
        XCTAssertTrue(contents.contains("level=notice"))
        XCTAssertTrue(contents.contains("level=error"))
        XCTAssertTrue(contents.contains("code=7"))
        XCTAssertTrue(contents.contains("label=app.test"))
    }
}
