import Foundation
import Darwin
import EasyMacMCP
import GuessWhoMCPWire
import Logging

/// A FIFO line reader built on `DispatchSourceRead`, enforcing a per-line
/// size cap DURING assembly.
///
/// ## Why not `FileHandle.bytes` (the inherited ReadPipe's engine)
///
/// Empirically (see `ReadPipeDeliveryTests`), `FileHandle.AsyncBytes`
/// stops delivering wakeups once a process holds roughly THREE
/// concurrently-parked FIFO reads — bytes sit unread in the FIFO while
/// `next()` never resumes. The inherited design never hits this (its host
/// parks exactly ONE reader — the shared central pipe — and each helper
/// process parks one), but OUR topology parks 1 announce + N per-helper
/// request readers in the app, so the app would wedge as soon as a second
/// helper connected. An event-driven read source scales to any N: nothing
/// parks; the kernel signals readability and the consumer drains
/// non-blocking.
///
/// ## Contract (mirrors the inherited ReadPipe where it matters)
///
/// * A keepalive `O_WRONLY` FD on the same FIFO keeps the kernel writer
///   count positive, so external writers detaching never EOFs the reader.
/// * `readLine()` returns the next non-empty line, `nil` only after
///   `close()`, and throws `CancellationError` when its task is cancelled
///   (cancellation also wakes a parked wait — no sentinel required,
///   though `signalReaderWake()` remains for the shared shutdown
///   sequence).
/// * Single consumer: one `readLine()` loop per pipe (both callers — the
///   request readers and the response router — honor this).
///
/// ## Caps
///
/// * `maxLineBytes` — a line that exceeds this flips the reader into
///   discard mode until the next newline: the flood streams to the floor
///   at O(cap) memory, is counted + logged, and (unparseable, so
///   unanswerable) times out sender-side.
/// * `softLimitBytes` — for the announce channel: any line above it logs
///   loudly and debug-asserts, because the shared announce FIFO is only
///   interleave-safe for writes ≤ PIPE_BUF (512 bytes on Darwin; Guard 1).
public actor CappedLineReadPipe: PipeReadable {
    private let fileURL: URL
    private let maxLineBytes: Int
    private let softLimitBytes: Int?
    private let logger: Logger?

    private var readerFD: Int32 = -1
    private var keepaliveWriterFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let readableSignal = PipeSignal()
    private var isOpen = false
    private var sawEOF = false

    /// Bytes drained from the FD but not yet consumed into lines.
    private var pendingBytes: [UInt8] = []
    /// Length of the trailing partial (un-terminated) line, tracked
    /// incrementally so the cap check is O(1) per byte.
    private var partialLineLength = 0
    private var isDiscardingOversizeLine = false
    public private(set) var droppedLineCount = 0

    public init(
        url: URL,
        maxLineBytes: Int = WireEnvironment.maxRequestLineBytes,
        softLimitBytes: Int? = nil,
        logger: Logger? = nil
    ) throws {
        guard url.isFileURL else { throw ReadPipeError.invalidURL }
        self.fileURL = url
        self.maxLineBytes = maxLineBytes
        self.softLimitBytes = softLimitBytes
        self.logger = logger

        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            if Self.isFIFO(path) { return }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                throw ReadPipeError.pipeAlreadyExists
            }
        }
        guard mkfifo(path, 0o600) == 0 else {
            throw ReadPipeError.failedToCreatePipe(String(cString: strerror(errno)))
        }
        guard Self.isFIFO(path) else { throw ReadPipeError.notAPipe }
    }

    deinit {
        // By deinit, every consumer task has exited (the documented
        // cancel → wake → await → close sequence), so plain cleanup is
        // safe. Cancelling the source is what closes the reader FD via
        // its cancel handler; if the source never existed, close directly.
        if let source {
            source.cancel()
        } else if readerFD >= 0 {
            Darwin.close(readerFD)
        }
        if keepaliveWriterFD >= 0 {
            Darwin.close(keepaliveWriterFD)
        }
    }

    public func open() async throws {
        guard !isOpen else { throw ReadPipeError.pipeAlreadyOpen }
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ReadPipeError.pipeDoesNotExist
        }
        guard Self.isFIFO(path) else { throw ReadPipeError.notAPipe }

        // O_NONBLOCK stays SET on the reader: all reads are drains driven
        // by the source's readability events, never parked read(2) calls.
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK, 0)
        guard fd != -1 else {
            throw ReadPipeError.openFailed(String(cString: strerror(errno)))
        }

        let keepaliveFD = Darwin.open(path, O_WRONLY | O_NONBLOCK, 0)
        guard keepaliveFD != -1 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ReadPipeError.keepaliveOpenFailed(message)
        }

        readerFD = fd
        keepaliveWriterFD = keepaliveFD

        let queue = DispatchQueue(label: "com.milestonemade.guesswho.mcp.pipe-read")
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let signal = readableSignal
        readSource.setEventHandler {
            signal.signal()
        }
        readSource.setCancelHandler {
            Darwin.close(fd)
            signal.signal() // wake any final waiter so it can observe close
        }
        readSource.resume()
        source = readSource
        isOpen = true
    }

    public func readLine() async throws -> String? {
        while true {
            if Task.isCancelled { throw CancellationError() }
            if let line = extractLine() {
                if line.isEmpty { continue } // sentinel / keepalive noise
                return line
            }
            guard isOpen else { return nil }
            if sawEOF { return nil }
            if drainAvailable() == 0 {
                await readableSignal.wait()
            }
        }
    }

    /// Wake a consumer parked in `readLine()` so it can observe
    /// cancellation — kept for the shared shutdown sequence, though task
    /// cancellation alone also wakes the wait.
    public nonisolated func signalReaderWake() {
        readableSignal.signal()
    }

    /// Close the pipe. Callers must have cancelled + awaited their reader
    /// task first (same contract as the inherited ReadPipe). Cancelling
    /// the dispatch source closes the reader FD via its cancel handler.
    public func close() async {
        guard isOpen else { return }
        isOpen = false
        if let source {
            source.cancel()
            self.source = nil
        } else if readerFD >= 0 {
            Darwin.close(readerFD)
        }
        readerFD = -1
        if keepaliveWriterFD >= 0 {
            Darwin.close(keepaliveWriterFD)
            keepaliveWriterFD = -1
        }
        readableSignal.signal()
    }

    // MARK: - Draining & line assembly

    /// Drain whatever the FIFO holds right now (non-blocking) into the
    /// pending buffer, applying the oversize cap as bytes stream through.
    /// Returns the number of bytes consumed from the FD.
    private func drainAvailable() -> Int {
        guard readerFD >= 0 else { return 0 }
        var total = 0
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(readerFD, &chunk, chunk.count)
            if count > 0 {
                total += count
                ingest(chunk[0..<count])
                if count < chunk.count { break }
            } else if count == 0 {
                // True EOF is impossible while the keepalive holds the
                // writer count up; if it happens, the FDs are gone.
                sawEOF = true
                break
            } else {
                let code = errno
                if code == EINTR { continue }
                // EAGAIN/EWOULDBLOCK: drained dry.
                break
            }
        }
        return total
    }

    /// Feed drained bytes through the cap/discard state machine into the
    /// line buffer.
    private func ingest(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if isDiscardingOversizeLine {
                if byte == 0x0A {
                    isDiscardingOversizeLine = false
                    droppedLineCount += 1
                    logger?.error("CAPPED_READ_PIPE: dropped line over \(maxLineBytes) bytes (total dropped: \(droppedLineCount))")
                }
                continue
            }
            if byte == 0x0A {
                pendingBytes.append(byte)
                partialLineLength = 0
                continue
            }
            pendingBytes.append(byte)
            partialLineLength += 1
            if partialLineLength > maxLineBytes {
                // Roll back the partial line and discard the remainder of
                // the flood as it streams.
                pendingBytes.removeLast(partialLineLength)
                partialLineLength = 0
                isDiscardingOversizeLine = true
            }
        }
    }

    /// Pop the next complete line (may be empty for bare newlines);
    /// nil when no full line is buffered.
    private func extractLine() -> String? {
        guard let newlineIndex = pendingBytes.firstIndex(of: 0x0A) else { return nil }
        var lineBytes = Array(pendingBytes[..<newlineIndex])
        pendingBytes.removeSubrange(...newlineIndex)
        if lineBytes.last == 0x0D { lineBytes.removeLast() }
        if let soft = softLimitBytes, lineBytes.count > soft {
            logger?.error("CAPPED_READ_PIPE: control line of \(lineBytes.count) bytes exceeds the \(soft)-byte announce budget — control messages must stay tiny")
            assertionFailure("Announce-channel message exceeded PIPE_BUF-safe budget")
        }
        return String(decoding: lineBytes, as: UTF8.self)
    }

    private static func isFIFO(_ path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFIFO
    }
}

/// Bridges dispatch-queue readiness events to a single awaiting
/// consumer. Lock-guarded (the event handler runs on a dispatch queue,
/// outside any actor); supports cancellation by resuming the waiter, whose
/// loop then observes `Task.isCancelled`.
final class PipeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var pendingSignal = false

    func signal() {
        lock.lock()
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume()
        } else {
            pendingSignal = true
            lock.unlock()
        }
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if pendingSignal || Task.isCancelled {
                    pendingSignal = false
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            signal()
        }
    }
}
