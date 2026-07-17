import XCTest
import Darwin
import EasyMacMCP
import GuessWhoMCPTransport

/// Delivery guarantees of the DispatchSource-based pipe pair.
///
/// HISTORY (do not re-simplify onto the platform conveniences — both
/// hazards were measured here, not theorized):
///
/// 1. `FileHandle.AsyncBytes` (the inherited ReadPipe's engine) stops
///    delivering wakeups once a process holds ~3 concurrently-parked FIFO
///    reads. Our topology parks 1 announce + N per-helper request readers
///    in the app, so reads moved to `DispatchSourceRead`
///    (`CappedLineReadPipe`). `testManyParkedReadersAllDeliver` guards it.
/// 2. A single `write(2)` larger than ~4KB to a FIFO whose reader waits on
///    a kqueue read source produces NO readable events until the write
///    completes — which it can't, because the reader never drains: a
///    kernel-level mutual wedge (measured threshold: 4KB delivers, 8KB
///    never does). The inherited `WritePipe` hands whole payloads to one
///    write, so large messages moved to `ChunkedWritePipe` (≤4KB per
///    write(2), writability-event waits).
///    `testLargeMessageDeliversThroughChunkedWriter` guards it.
final class ReadPipeDeliveryTests: XCTestCase {
    private var fifoURL: URL!

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
        fifoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-test-\(UUID().uuidString).fifo")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fifoURL)
        super.tearDown()
    }

    func testTwoSeparatedWritesDeliver() async throws {
        let reader = try CappedLineReadPipe(url: fifoURL, maxLineBytes: 1024)
        try await reader.open()
        let writer = try ChunkedWritePipe(url: fifoURL)
        try await writer.open()

        try await writer.write("first-line\n")
        let first = try await reader.readLine()
        XCTAssertEqual(first, "first-line")

        try await Task.sleep(nanoseconds: 100_000_000)
        try await writer.write("second-line\n")
        let second = try await reader.readLine()
        XCTAssertEqual(second, "second-line")

        await writer.close()
        await reader.close()
    }

    /// Reader parked BEFORE the writer even opens (the session topology).
    func testReaderParkedBeforeWriterOpensDeliversSecondWrite() async throws {
        let reader = try CappedLineReadPipe(url: fifoURL, maxLineBytes: 4096)
        try await reader.open()

        let firstParked = Task { try await reader.readLine() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let writer = try ChunkedWritePipe(url: fifoURL)
        try await writer.open()
        try await writer.write("first-line\n")
        let first = try await firstParked.value
        XCTAssertEqual(first, "first-line")

        let secondParked = Task { try await reader.readLine() }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await writer.write("second-line\n")
        let second = try await secondParked.value
        XCTAssertEqual(second, "second-line")

        await writer.close()
        await reader.close()
    }

    /// FIVE readers parked at once in one process, then writes to each —
    /// the load shape the app host actually runs (announce + N helpers).
    /// This is the FileHandle.AsyncBytes regression guard.
    func testManyParkedReadersAllDeliver() async throws {
        let urls = (0..<5).map { index in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("many-parked-\(index)-\(UUID().uuidString).fifo")
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        var readers: [CappedLineReadPipe] = []
        var parked: [Task<String?, Error>] = []
        for url in urls {
            let reader = try CappedLineReadPipe(url: url, maxLineBytes: 4096)
            try await reader.open()
            readers.append(reader)
            parked.append(Task { try await reader.readLine() })
        }
        try await Task.sleep(nanoseconds: 300_000_000) // all five parked

        for (index, url) in urls.enumerated().reversed() {
            let writer = try ChunkedWritePipe(url: url)
            try await writer.open()
            try await writer.write("wake-\(index)\n")
            let line = try await parked[index].value
            XCTAssertEqual(line, "wake-\(index)", "parked reader \(index) never woke")
            await writer.close()
        }

        for reader in readers { await reader.close() }
    }

    /// A message far above the single-write(2) hazard threshold delivers
    /// intact through the chunked writer — the large-write regression
    /// guard.
    func testLargeMessageDeliversThroughChunkedWriter() async throws {
        let reader = try CappedLineReadPipe(url: fifoURL, maxLineBytes: 1_048_576)
        try await reader.open()

        let parked = Task { try await reader.readLine() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let writer = try ChunkedWritePipe(url: fifoURL)
        try await writer.open()
        let payload = String(repeating: "large-line-payload-", count: 3000) // ~57KB
        let writeTask = Task { try await writer.write(payload + "\n") }

        let line = try await parked.value
        XCTAssertEqual(line?.count, payload.count, "large line arrived truncated or not at all")
        XCTAssertEqual(line, payload)
        try await writeTask.value

        await writer.close()
        await reader.close()
    }

    /// Whole messages from concurrent writes on ONE pipe never interleave
    /// chunks (the writer serializes messages internally).
    func testConcurrentMessagesOnOneWriterDoNotInterleave() async throws {
        let reader = try CappedLineReadPipe(url: fifoURL, maxLineBytes: 1_048_576)
        try await reader.open()
        let writer = try ChunkedWritePipe(url: fifoURL)
        try await writer.open()

        let messageA = String(repeating: "A", count: 20_000)
        let messageB = String(repeating: "B", count: 20_000)
        async let writeA: Void = writer.write(messageA + "\n")
        async let writeB: Void = writer.write(messageB + "\n")

        let first = try await reader.readLine()
        let second = try await reader.readLine()
        _ = try await (writeA, writeB)

        let lines = Set([first, second].compactMap { $0 })
        XCTAssertEqual(lines, Set([messageA, messageB]), "concurrent messages interleaved or tore")

        await writer.close()
        await reader.close()
    }

    /// Cancellation alone unparks a waiting readLine (no wedge on close).
    func testCancellationUnparksReader() async throws {
        let reader = try CappedLineReadPipe(url: fifoURL, maxLineBytes: 4096)
        try await reader.open()

        let parked = Task { try await reader.readLine() }
        try await Task.sleep(nanoseconds: 200_000_000)
        parked.cancel()
        do {
            _ = try await parked.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        await reader.close()
    }
}
