import XCTest
import Darwin
@testable import GuessWhoMCPTransport

/// Lock-guarded, Sendable counter the write-source fire probe increments from
/// the dispatch event-handler thread. `@unchecked Sendable` + `NSLock` makes
/// the cross-thread increment race-free without an actor hop.
private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Regression guard for the idle CPU spin: an always-armed
/// `DispatchSourceWrite` is level-triggered on writability, and an idle FIFO is
/// always writable, so the write-source event handler busy-loops. This test
/// asserts the handler fires ZERO times while the pipe is open and idle.
///
/// It is written RED-FIRST: against the current always-armed source it fails
/// (the counter climbs without bound). Once the source is gated (armed only
/// around an EAGAIN wait), it passes.
final class WriteSourceIdleSpinTests: XCTestCase {
    private var container: URL!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-idle-spin-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let container {
            try? FileManager.default.removeItem(at: container)
        }
        super.tearDown()
    }

    func testIdleWriteSourceDoesNotSpin() async throws {
        let url = container.appendingPathComponent("idle-\(UUID().uuidString).pipe")

        // Constructing the pipe mkfifo()s the path.
        let pipe = try ChunkedWritePipe(url: url)

        // Hold the read end open so the writer's O_WRONLY|O_NONBLOCK open does
        // not fail with ENXIO. Nonblocking read-open succeeds with no writer.
        let readerFD = Darwin.open(url.path, O_RDONLY | O_NONBLOCK, 0)
        XCTAssertNotEqual(readerFD, -1,
            "failed to open reader fd: \(String(cString: strerror(errno)))")
        defer { Darwin.close(readerFD) }

        let counter = FireCounter()
        await pipe._setOnSourceFire { counter.increment() }
        try await pipe.open()

        // Idle: send nothing. Let the run loop settle.
        try await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        let fires = counter.count
        await pipe.close()

        XCTAssertEqual(fires, 0,
            "write source fired \(fires) times while the pipe was open and idle — the pipe-write DispatchSource is busy-looping")
    }
}
