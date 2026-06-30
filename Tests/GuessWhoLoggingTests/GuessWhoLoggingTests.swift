import XCTest
import Logging
@testable import GuessWhoLogging

/// Tests for the surface `GuessWhoLogging` still owns after the FellerBuncher
/// migration: the `GuessWhoLog` bootstrap facade (idempotent + crash-safe), the
/// `Logger+Convenience` metadata-bag sugar (pure swift-log, backend-agnostic),
/// and the `LogExporter`. The logfmt formatting, file writing, rotation, and
/// pruning are now FellerBuncher's responsibility and are covered by its own
/// test suite — we no longer re-test them here.
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

    // MARK: - Bootstrap facade: idempotent + crash-safe

    func testDoubleBootstrapDoesNotTrap() {
        // FellerBuncher's bootstrap returns the existing handle on a second
        // call rather than trapping, so calling our facade twice is safe.
        GuessWhoLog.bootstrap(processName: "app", appGroupID: "test.group", baseOverride: tempBase)
        GuessWhoLog.bootstrap(processName: "app", appGroupID: "test.group", baseOverride: tempBase)
        // A logger is obtainable and usable.
        let logger = GuessWhoLog.logger("test")
        logger.info("after double bootstrap")
        XCTAssertTrue(true)
    }

    func testConcurrentBootstrapDoesNotTrap() {
        // Many threads racing bootstrap must not double-call
        // LoggingSystem.bootstrap (which would trap).
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

    func testBootstrapWithUnwritableDirectoryDoesNotCrash() throws {
        // Point the base at a path under a regular file (not a directory) so the
        // Logs dir can't be created. Bootstrap must degrade gracefully — logging
        // is never fatal.
        let bogusParent = tempBase.appendingPathComponent("not-a-dir")
        FileManager.default.createFile(atPath: bogusParent.path, contents: Data("x".utf8))

        GuessWhoLog.bootstrap(processName: "app", appGroupID: "test.group", baseOverride: bogusParent)
        let logger = GuessWhoLog.logger("test")
        logger.error("this should not crash")
        // Reaching here without a crash/throw is the assertion.
        XCTAssertTrue(true)
    }

    // MARK: - Directory resolution

    func testLogsDirectoryResolvesUnderBaseOverride() throws {
        let dir = LogDestination.logsDirectoryURL(appGroupID: "test.group", baseOverride: tempBase)
        XCTAssertNotNil(dir, "a writable base override should resolve a Logs dir")
        XCTAssertEqual(dir?.lastPathComponent, "Logs")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir!.path, isDirectory: &isDir) && isDir.boolValue,
            "the resolved Logs dir should exist on disk"
        )
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

    // MARK: - Convenience metadata sugar (pure swift-log, backend-agnostic)

    /// The `log.info("msg", ["key": value])` sugar bridges a plain
    /// `[String: CustomStringConvertible]` bag into `Logger.Metadata`, rendering
    /// each value via its own `description` (so `Int`, `String`, and a `URL`'s
    /// path all flatten correctly). Backend-agnostic — we capture what reaches
    /// the handler via a recording test handler.
    func testConvenienceMetadataOverloadBridgesStringConvertible() throws {
        let recorder = MetadataRecorder()
        var logger = Logger(label: "app.test", factory: { _ in recorder })
        logger.logLevel = .trace

        let url = URL(fileURLWithPath: "/tmp/handoff.json")
        logger.notice("park: wrote OK", ["bytes": 1234, "path": url.path, "stage": "extension"])

        // `.stringConvertible` renders as the value's `description`; comparing the
        // rendered strings keeps the assertion independent of the wrapper type.
        let captured = recorder.lastMetadata
        XCTAssertEqual(captured?["bytes"], "1234", "Int value renders via description")
        XCTAssertEqual(captured?["stage"], "extension", "String value renders")
        XCTAssertEqual(captured?["path"], url.path, "URL path value renders")
    }

    /// Captures the metadata of the most recent record, rendered to strings, so
    /// tests can assert on values regardless of which `MetadataValue` case the
    /// convenience bridge chose.
    private final class MetadataRecorder: LogHandler, @unchecked Sendable {
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        private(set) var lastMetadata: [String: String]?

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata: Logger.Metadata?,
            source: String,
            file: String,
            function: String,
            line: UInt
        ) {
            lastMetadata = (metadata ?? [:]).mapValues { "\($0)" }
        }
    }
}
