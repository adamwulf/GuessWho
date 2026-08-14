import XCTest
import Darwin
import EasyMacMCP
@testable import GuessWhoMCPTransport

/// Lock-guarded, Sendable counter incremented from either the dispatch
/// event-handler thread or the actor's write task.
private final class Counter: @unchecked Sendable {
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

/// Exercises the gated write source's lifecycle edges: the one-shot reopen
/// guard (Part B), the resume-before-cancel that keeps releasing an
/// inactive/suspended source from crashing libdispatch, and the arm/disarm
/// backpressure path (Part A) — including tearing-down while a writer is parked
/// on `EAGAIN`.
final class WriteSourceLifecycleTests: XCTestCase {
    private var container: URL!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-write-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let container {
            try? FileManager.default.removeItem(at: container)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Open a fresh FIFO writer plus a held reader fd (so the writer's
    /// `O_WRONLY|O_NONBLOCK` open does not ENXIO). Returns both; the caller
    /// closes the reader fd.
    private func makePipeWithReader(_ name: String) throws -> (ChunkedWritePipe, Int32, URL) {
        let url = container.appendingPathComponent("\(name)-\(UUID().uuidString).pipe")
        let pipe = try ChunkedWritePipe(url: url)
        let readerFD = Darwin.open(url.path, O_RDONLY | O_NONBLOCK, 0)
        XCTAssertNotEqual(readerFD, -1,
            "failed to open reader fd: \(String(cString: strerror(errno)))")
        return (pipe, readerFD, url)
    }

    /// Poll `cond` up to `iterations` times with a short sleep between checks.
    /// Bounded so a lost wake fails fast instead of hanging the suite.
    @discardableResult
    private func waitUntil(iterations: Int = 500,
                           sleepNs: UInt64 = 10_000_000,
                           _ cond: () -> Bool) async throws -> Bool {
        for _ in 0..<iterations {
            if cond() { return true }
            try await Task.sleep(nanoseconds: sleepNs)
        }
        return cond()
    }

    /// Read up to `cap` bytes once (non-blocking) into `sink`. Returns bytes
    /// read (0 on EAGAIN). A bounded single read keeps the kernel buffer full
    /// enough that the writer re-blocks, forcing multiple EAGAIN cycles.
    private func readOnce(_ fd: Int32, cap: Int, into sink: inout Data) -> Int {
        var buf = [UInt8](repeating: 0, count: cap)
        while true {
            let n = buf.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress, cap) }
            if n > 0 { sink.append(contentsOf: buf[0..<n]); return n }
            if n < 0 && errno == EINTR { continue }
            return 0
        }
    }

    /// Poll a Task's completion flag with a bounded deadline WITHOUT
    /// structurally awaiting the task (a task group would wait for its
    /// cancelled child on scope exit, and `Task.value` does not return on the
    /// awaiter's cancellation — so a parked writer would still hang). Returns
    /// true if the flag was set within the deadline. On false, the caller
    /// unwinds the wedged writer with `await pipe.close()` (which signals the
    /// parked wait so its inner task can finish) and fails fast.
    private func awaitFlag(_ flag: Counter,
                           deadlineSeconds: Double = 10) async throws -> Bool {
        let iterations = max(1, Int(deadlineSeconds * 100))
        return try await waitUntil(iterations: iterations, sleepNs: 10_000_000) { flag.count > 0 }
    }

    /// Lock-guarded, Sendable holder so a write Task can hand its thrown error
    /// back to the test without an un-Sendable `Error?` crossing a task group.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: - Part B: one-shot reopen guard

    func testReopenAfterCloseThrowsPipeClosed() async throws {
        let (pipe, readerFD, _) = try makePipeWithReader("reopen")
        defer { Darwin.close(readerFD) }

        try await pipe.open()
        await pipe.close()

        do {
            try await pipe.open()
            XCTFail("expected ChunkedWritePipeError.pipeClosed on reopen")
        } catch ChunkedWritePipeError.pipeClosed {
            // expected
        }
    }

    // MARK: - close() of an inactive source must not crash (release-of-inactive)

    /// With no write, the source stays inactive. `close()` must resume it
    /// before cancel; otherwise releasing an inactive source aborts
    /// libdispatch. If that regressed, this test would crash the run.
    func testCloseOfInactiveSourceRejectsSubsequentWrites() async throws {
        let (pipe, readerFD, _) = try makePipeWithReader("inactive-close")
        defer { Darwin.close(readerFD) }

        try await pipe.open()   // source created inactive; never armed
        await pipe.close()      // resume-before-cancel of an INACTIVE source

        do {
            try await pipe.write(Data("late".utf8))
            XCTFail("expected pipeNotOpened after close")
        } catch WritePipeError.pipeNotOpened {
            // expected
        }
    }

    // MARK: - Part A: arm/disarm delivers under real backpressure

    /// Forces multiple EAGAIN cycles (proving arm/wait/disarm repeats), checks
    /// the payload survives intact, and — the load-bearing part — proves the
    /// source goes QUIET after the write finishes. Removing `disarmSource()`
    /// would leave the source armed after the first backpressure event and
    /// re-introduce the spin; only the post-write-quiet assertion catches that.
    func testBackpressureCyclesDisarmAndDeliverIntact() async throws {
        let (pipe, readerFD, _) = try makePipeWithReader("backpressure")
        defer { Darwin.close(readerFD) }

        let blocks = Counter()   // onWouldBlock: one per EAGAIN transition
        let fires = Counter()    // onSourceFire: one per write-source handler entry
        await pipe._setOnWouldBlock { blocks.increment() }
        await pipe._setOnSourceFire { fires.increment() }
        try await pipe.open()

        // Larger than any FIFO kernel buffer, so the writer must block repeatedly.
        let total = 512 * 1024
        let payload = Data((0..<total).map { UInt8(truncatingIfNeeded: $0) })

        // Write concurrently; do NOT drain yet, so the buffer fills and the
        // writer parks on EAGAIN (deterministic first block). Fire-and-forget:
        // pipe.write() parks inside its OWN inner serialization Task, so
        // cancelling this outer Task would not reach it — we bound completion
        // via `done`/awaitFlag and unwind with close() if it ever wedges.
        let done = Counter()
        let errorBox = ErrorBox()
        Task {
            do { try await pipe.write(payload) } catch { errorBox.set(error) }
            done.increment()
        }

        let blocked = try await waitUntil { blocks.count >= 1 }
        XCTAssertTrue(blocked, "writer never hit EAGAIN — backpressure path not exercised")

        // Drain in bounded 16 KB reads so the buffer stays near-full and the
        // writer re-blocks many times. Bounded by an idle-read budget so a
        // stall fails fast instead of looping forever.
        var received = Data()
        received.reserveCapacity(total)
        var idleReads = 0
        while received.count < total {
            let n = readOnce(readerFD, cap: 16 * 1024, into: &received)
            if n > 0 { idleReads = 0; continue }
            idleReads += 1
            if idleReads > 3000 { break } // ~6s with no progress
            try await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }

        // Deadline-bounded via a completion flag (never a structured await of
        // the writer), so a lost wake fails fast instead of hanging the suite.
        if try await awaitFlag(done) == false {
            // Unwind the wedged writer: close() signals writableSignal, waking
            // the parked wait so its inner task can throw and finish.
            await pipe.close()
            return XCTFail("writer did not complete within the deadline — lost wake?")
        }
        if let err = errorBox.get() {
            await pipe.close()
            return XCTFail("write failed under backpressure: \(err)")
        }

        XCTAssertEqual(received.count, total, "payload truncated across backpressure")
        XCTAssertEqual(received, payload, "payload corrupted across backpressure")
        XCTAssertGreaterThanOrEqual(blocks.count, 2,
            "expected multiple EAGAIN cycles; arm/wait/disarm did not repeat")

        // Post-write disarm: with the pipe drained and the write finished, the
        // source must be inactive. Sample the handler-fire count, let it settle,
        // and assert it does not move. If `disarmSource()` regressed, the source
        // would stay armed on the now-writable empty FIFO and spin here.
        let firesAfterWrite = fires.count
        try await Task.sleep(nanoseconds: 150_000_000) // 150 ms
        XCTAssertEqual(fires.count, firesAfterWrite,
            "write source kept firing after the write completed — it was not disarmed")

        await pipe.close()
    }

    // MARK: - close() while a writer is parked on EAGAIN

    func testCloseWhileWriterParkedThrowsPipeNotOpened() async throws {
        let (pipe, readerFD, _) = try makePipeWithReader("close-parked")
        defer { Darwin.close(readerFD) }

        let blocks = Counter()
        await pipe._setOnWouldBlock { blocks.increment() }
        try await pipe.open()

        let payload = Data(repeating: 0x41, count: 512 * 1024)
        let done = Counter()
        let errorBox = ErrorBox()
        Task {
            do { try await pipe.write(payload) } catch { errorBox.set(error) }
            done.increment()
        }

        // Wait until the writer is parked (source armed), never draining.
        let blocked = try await waitUntil { blocks.count >= 1 }
        XCTAssertTrue(blocked, "writer never parked on EAGAIN")

        // Close while parked: the source is armed, so close() cancels without
        // an extra resume; the parked writer wakes to fd == -1 and fails.
        await pipe.close()

        // Deadline-bounded on a completion flag so a lost close-signal fails
        // fast instead of hanging.
        if try await awaitFlag(done) == false {
            await pipe.close()   // re-signal the parked wait; the pipe is already closed
            return XCTFail("parked writer did not unwind after close — lost close signal?")
        }
        let result = errorBox.get()
        guard case WritePipeError.pipeNotOpened? = result else {
            return XCTFail("expected pipeNotOpened, got \(String(describing: result))")
        }
    }

    // MARK: - deinit without close (self-relaunching subprocess)

    private static let deinitProbeEnvKey = "GUESSWHO_DEINIT_PROBE"
    private static let deinitSentinelEnvKey = "GUESSWHO_DEINIT_SENTINEL"

    /// The CHILD scenario. It only does work when re-launched by the parent
    /// with `GUESSWHO_DEINIT_PROBE=1`; otherwise it is a no-op that passes
    /// trivially in the normal `swift test` run. It opens a writer (installing
    /// an inactive source), drops it WITHOUT `close()`, and lets `deinit` run.
    /// If `deinit` failed to resume-before-cancel, releasing the inactive
    /// source would abort libdispatch and crash this child process.
    func testDeinitProbeChild() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.deinitProbeEnvKey] == "1" else {
            return // parent run: nothing to do here
        }

        let url = container.appendingPathComponent("deinit-\(UUID().uuidString).pipe")
        // Hold a reader so the writer open does not ENXIO. Outlives the pipe.
        var pipe: ChunkedWritePipe? = try ChunkedWritePipe(url: url)
        weak let weakPipe = pipe
        let readerFD = Darwin.open(url.path, O_RDONLY | O_NONBLOCK, 0)
        XCTAssertNotEqual(readerFD, -1)
        defer { Darwin.close(readerFD) }

        try await pipe!.open()   // installs an INACTIVE source
        pipe = nil               // drop the last ref: deinit runs, no close()

        // Give deinit + the source's async cancel handler time to run.
        try await Task.sleep(nanoseconds: 100_000_000)

        // The actor MUST have deallocated: proves deinit actually ran. If a
        // future change made the source handler capture `self`, the live source
        // would keep the actor alive, deinit would never run, and this child
        // would exit 0 without exercising anything — a vacuous pass. This
        // assertion closes that hole.
        XCTAssertNil(weakPipe, "pipe did not deallocate — deinit did not run (handler may retain the actor)")

        // Prove the scenario actually executed (guards against a mis-filtered
        // child that runs zero tests yet exits 0).
        if let sentinel = env[Self.deinitSentinelEnvKey] {
            try Data("ran".utf8).write(to: URL(fileURLWithPath: sentinel))
        }
    }

    /// The PARENT driver. Re-launches this test bundle for just
    /// `testDeinitProbeChild` in a child process with the probe env set, and
    /// asserts the child exited cleanly (no libdispatch abort) and actually ran
    /// (sentinel present). Skips if the xctest runner/bundle cannot be located.
    func testDeinitWithoutCloseDoesNotAbort() throws {
        // Only act as the parent. If invoked as the child by some other path,
        // do nothing (the child work lives in testDeinitProbeChild).
        guard ProcessInfo.processInfo.environment[Self.deinitProbeEnvKey] != "1" else { return }

        guard let (xctestURL, bundlePath) = Self.locateXCTestRunner() else {
            throw XCTSkip("could not locate the xctest runner/bundle to spawn a subprocess")
        }

        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-deinit-sentinel-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }

        let proc = Process()
        proc.executableURL = xctestURL
        proc.arguments = ["-XCTest", "WriteSourceLifecycleTests/testDeinitProbeChild", bundlePath]
        var env = ProcessInfo.processInfo.environment
        env[Self.deinitProbeEnvKey] = "1"
        env[Self.deinitSentinelEnvKey] = sentinel.path
        proc.environment = env
        let sink = Pipe()
        proc.standardOutput = sink
        proc.standardError = sink

        try proc.run()

        // Bounded wait so a hung child fails fast instead of wedging the suite.
        let deadline = Date().addingTimeInterval(60)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return XCTFail("deinit-probe child timed out")
        }

        XCTAssertEqual(proc.terminationReason, .exit,
            "deinit-probe child terminated by signal — deinit likely aborted libdispatch")
        XCTAssertEqual(proc.terminationStatus, 0,
            "deinit-probe child failed (status \(proc.terminationStatus))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
            "deinit-probe child did not run the scenario (sentinel missing) — subprocess filter did not select it")
    }

    /// Best-effort discovery of the `xctest` tool and this test bundle so the
    /// parent can re-launch just the child test.
    private static func locateXCTestRunner() -> (URL, String)? {
        let bundlePath = Bundle(for: WriteSourceLifecycleTests.self).bundlePath
        guard bundlePath.hasSuffix(".xctest") else { return nil }

        // Prefer the runner that launched us, if it is xctest.
        if let arg0 = CommandLine.arguments.first, arg0.hasSuffix("/xctest"),
           FileManager.default.isExecutableFile(atPath: arg0) {
            return (URL(fileURLWithPath: arg0), bundlePath)
        }

        // Fall back to `xcrun -f xctest`.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        which.arguments = ["-f", "xctest"]
        let out = Pipe()
        which.standardOutput = out
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            guard which.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return (URL(fileURLWithPath: path), bundlePath)
        } catch {
            return nil
        }
    }
}
