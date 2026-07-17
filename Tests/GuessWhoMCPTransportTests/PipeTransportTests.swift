import XCTest
import Darwin
import GuessWhoMCPTransport
import GuessWhoMCPWire
import Logging

/// stderr logger for debugging transport tests; enabled via
/// GUESSWHO_MCP_TEST_LOGS=1.
private let testLogger: Logger? = {
    let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("guesswho-mcp-test-logs-on")
    guard ProcessInfo.processInfo.environment["GUESSWHO_MCP_TEST_LOGS"] == "1"
        || FileManager.default.fileExists(atPath: marker.path) else { return nil }
    var logger = Logger(label: "transport-tests") { label in
        StreamLogHandler.standardError(label: label)
    }
    logger.logLevel = .info
    return logger
}()

/// End-to-end transport tests over REAL FIFOs in a temp-dir container:
/// the concurrent >PIPE_BUF round trip (the headline fix the per-helper
/// request pipe exists for), framing injection, rapid helper churn, host
/// restart under a live helper, and the request-size cap.
final class PipeTransportTests: XCTestCase {
    private var container: URL!

    override func setUp() {
        super.setUp()
        // EPIPE must surface as a thrown write error, not kill the test
        // process — same posture the relay takes at startup.
        signal(SIGPIPE, SIG_IGN)
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let container {
            try? FileManager.default.removeItem(at: container)
        }
        super.tearDown()
    }

    /// Echo host: answers contacts_search with the query text so tests can
    /// verify byte-for-byte integrity end to end.
    private func makeEchoHost() -> MCPPipeHost {
        MCPPipeHost(container: container, handler: { request in
            if case .contactsSearch(let helperId, let messageId, let query, _, _) = request {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .invalidParams, message: query)
            }
            return .error(
                helperId: request.helperId, messageId: request.messageId,
                code: .invalidParams, message: "unhandled")
        }, logger: testLogger)
    }

    private func makeHelper() -> RelayConnection {
        RelayConnection(
            helperId: RequestOrigin.mcp.makeHelperId(),
            container: container,
            logger: testLogger,
            readyTimeout: 5)
    }

    private func echo(_ helper: RelayConnection, query: String, line: UInt = #line) async throws -> String {
        let response = try await helper.send(
            .contactsSearch(
                helperId: helper.helperId, messageId: "echo-\(UUID().uuidString.prefix(8))-\(line)",
                query: query, limit: nil, cursor: nil),
            timeout: 10)
        guard let payload = response.errorPayload else {
            XCTFail("expected echo payload", line: line)
            return ""
        }
        return payload.message
    }

    // MARK: - The headline fix

    /// Two helpers concurrently sending requests far over PIPE_BUF (512B)
    /// must each round-trip byte-for-byte intact. On the old shared
    /// request pipe this interleaves and tears; per-helper pipes make it
    /// structurally impossible.
    func testConcurrentLargeRequestsFromTwoHelpersArriveIntact() async throws {
        let host = makeEchoHost()
        try await host.startListening()
        let helperA = makeHelper()
        let helperB = makeHelper()
        try await helperA.connect()
        try await helperB.connect()

        let payloadA = "A" + String(repeating: "alpha-payload-", count: 600) // ~8.4KB
        let payloadB = "B" + String(repeating: "bravo-payload-", count: 600)

        for _ in 0..<5 {
            async let echoA = echo(helperA, query: payloadA)
            async let echoB = echo(helperB, query: payloadB)
            let (resultA, resultB) = try await (echoA, echoB)
            XCTAssertEqual(resultA, payloadA, "helper A's large request tore in transit")
            XCTAssertEqual(resultB, payloadB, "helper B's large request tore in transit")
        }

        await helperA.disconnect()
        await helperB.disconnect()
        await host.stopListening()
    }

    // MARK: - Framing injection

    func testInjectionValuesStayOneMessageOverThePipes() async throws {
        let host = makeEchoHost()
        try await host.startListening()
        let helper = makeHelper()
        try await helper.connect()

        for payload in [
            "two\nlines", "carriage\rreturn", "forged }\n{\"deinitialize\":{}} frame",
        ] {
            let echoed = try await echo(helper, query: payload)
            XCTAssertEqual(echoed, payload, "injection payload was mangled or split")
        }

        await helper.disconnect()
        await host.stopListening()
    }

    // MARK: - Churn

    /// Rapid connect / use / disconnect cycles must not wedge the host or
    /// leak sessions (guards the awaited-per-pipe teardown).
    func testRapidHelperChurnLeavesNoSessionsBehind() async throws {
        let host = makeEchoHost()
        try await host.startListening()

        for round in 0..<8 {
            let helper = makeHelper()
            try await helper.connect()
            let echoed = try await echo(helper, query: "round-\(round)")
            XCTAssertEqual(echoed, "round-\(round)")
            await helper.disconnect()
        }

        // Deinitialize is processed asynchronously by the announce reader;
        // poll briefly for the last teardown to land.
        for _ in 0..<50 {
            if await host.sessionCount == 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let remaining = await host.sessionCount
        XCTAssertEqual(remaining, 0, "helper sessions leaked across churn")
        await host.stopListening()
    }

    // MARK: - Host restart under a live helper

    /// Quit + relaunch the app while a helper stays alive: the helper's
    /// next call must succeed after its automatic re-handshake, and the
    /// new host's launch sweep must not wedge it.
    func testHostRestartUnderLiveHelperRecovers() async throws {
        let host1 = makeEchoHost()
        try await host1.startListening()
        let helper = makeHelper()
        try await helper.connect()
        let before = try await echo(helper, query: "before-restart")
        XCTAssertEqual(before, "before-restart")

        await host1.stopListening()

        let host2 = makeEchoHost()
        try await host2.startListening() // sweeps the per-helper FIFOs

        let after = try await echo(helper, query: "after-restart")
        XCTAssertEqual(after, "after-restart", "helper did not recover after the app restarted")
        let sessions = await host2.sessionCount
        XCTAssertEqual(sessions, 1, "the recovered helper should hold exactly one session")

        await helper.disconnect()
        await host2.stopListening()
    }

    // MARK: - No host

    func testNoHostFailsFastWithNotRunning() async throws {
        let helper = makeHelper()
        let started = Date()
        do {
            try await helper.connect()
            XCTFail("connect must fail with no app listening")
        } catch let error as RelayConnectionError {
            guard case .hostNotRunning = error else {
                return XCTFail("expected the not-running verdict, got \(error)")
            }
            XCTAssertEqual(error.description, WireErrorMessage.notRunning)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "no-host probe must fail fast, not hang")
    }

    // MARK: - Request-size cap

    /// An oversize line is discarded DURING assembly and the next line
    /// still reads — the reader never buffers the flood.
    func testOversizeLineIsDroppedInStream() async throws {
        let fifoURL = container.appendingPathComponent("cap-test-fifo")
        let pipe = try CappedLineReadPipe(url: fifoURL, maxLineBytes: 64)
        try await pipe.open()

        let fd = Darwin.open(fifoURL.path, O_WRONLY, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let oversize = String(repeating: "x", count: 300) + "\n"
        let normal = "hello-after-flood\n"
        _ = oversize.withCString { write(fd, $0, strlen($0)) }
        _ = normal.withCString { write(fd, $0, strlen($0)) }
        Darwin.close(fd)

        let line = try await pipe.readLine()
        XCTAssertEqual(line, "hello-after-flood", "the line after an oversize flood must still read")
        let dropped = await pipe.droppedLineCount
        XCTAssertEqual(dropped, 1)
        await pipe.close()
    }
}
