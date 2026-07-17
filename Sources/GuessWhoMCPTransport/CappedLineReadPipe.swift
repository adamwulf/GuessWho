import Foundation
import Darwin
import EasyMacMCP
import GuessWhoMCPWire
import Logging

/// A FIFO line reader that enforces a per-line size cap DURING assembly.
///
/// Mirrors EasyMacMCP's `ReadPipe` (same keepalive-FD, wake-sentinel, and
/// close-ordering contract — see that type's docs for the dispatch_io
/// rationale) with two deliberate differences:
///
/// * **Cap before reassembly.** `ReadPipe` hands the FD to
///   `AsyncLineSequence`, which will happily buffer a 500MB "line". This
///   reader assembles lines byte-by-byte and flips into discard mode the
///   moment a line crosses `maxLineBytes`, so an oversize request costs
///   O(cap) memory, not O(payload) (plans/cli-mcp.md request-size cap).
///   Discarded lines are counted and logged; they can't be answered
///   (their message id was never parsed), so the sender times out — the
///   documented cost of sending something enormous.
/// * **Soft limit for the announce channel.** When `softLimitBytes` is
///   set, any line above it logs loudly (and debug-asserts): the shared
///   announce FIFO is only interleave-safe for writes ≤ PIPE_BUF (512
///   bytes on Darwin), so a fat control message is a design regression
///   even when it happens to parse (Guard 1).
///
/// Conforms to `PipeReadable`, so `HostRequestPipe` drives it unchanged.
public actor CappedLineReadPipe: PipeReadable {
    private let fileURL: URL
    private let maxLineBytes: Int
    private let softLimitBytes: Int?
    private let logger: Logger?

    private var fileHandle: FileHandle?
    /// Persistent byte iterator — held across `readLine()` calls so the
    /// underlying `AsyncBytes` chunk buffer survives (a fresh iterator per
    /// call would silently drop buffered bytes).
    private var byteIterator: FileHandle.AsyncBytes.AsyncIterator?
    /// Self-pipe keepalive writer FD; see `ReadPipe` for why EOF must never
    /// be delivered on external-writer churn.
    private var keepaliveWriterFD: Int32?
    private var lineBuffer: [UInt8] = []
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
        // Mirrors ReadPipe.deinit: by the time deinit can run, every reader
        // Task has exited via the documented cancel → wake → await → close
        // sequence, so plain FD cleanup is safe here.
        if let fd = keepaliveWriterFD { Darwin.close(fd) }
        try? fileHandle?.close()
    }

    public func open() async throws {
        guard fileHandle == nil && keepaliveWriterFD == nil else {
            throw ReadPipeError.pipeAlreadyOpen
        }
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ReadPipeError.pipeDoesNotExist
        }
        guard Self.isFIFO(path) else { throw ReadPipeError.notAPipe }

        let readerFD = Darwin.open(path, O_RDONLY | O_NONBLOCK, 0)
        guard readerFD != -1 else {
            throw ReadPipeError.openFailed(String(cString: strerror(errno)))
        }
        let flags = fcntl(readerFD, F_GETFL)
        if flags != -1 {
            _ = fcntl(readerFD, F_SETFL, flags & ~O_NONBLOCK)
        }

        // Keepalive writer FD (never written except by signalReaderWake):
        // keeps the kernel writer count positive so external writers
        // detaching never EOFs the reader into a busy-spin.
        let keepaliveFD = Darwin.open(path, O_WRONLY | O_NONBLOCK, 0)
        guard keepaliveFD != -1 else {
            let message = String(cString: strerror(errno))
            Darwin.close(readerFD)
            throw ReadPipeError.keepaliveOpenFailed(message)
        }

        let handle = FileHandle(fileDescriptor: readerFD, closeOnDealloc: true)
        fileHandle = handle
        byteIterator = handle.bytes.makeAsyncIterator()
        keepaliveWriterFD = keepaliveFD
    }

    /// Next non-empty line, or nil when the pipe has been closed by us.
    /// Oversize lines are discarded in-stream (logged + counted) and never
    /// returned. Rethrows `CancellationError` unwrapped — the documented
    /// reader-shutdown signal.
    public func readLine() async throws -> String? {
        guard fileHandle != nil, var iterator = byteIterator else {
            throw ReadPipeError.pipeNotOpened
        }
        defer { byteIterator = iterator }

        while true {
            if Task.isCancelled { throw CancellationError() }
            let byte: UInt8?
            do {
                byte = try await iterator.next()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ReadPipeError.readError(error)
            }
            guard let byte else { return nil }

            if byte == 0x0A { // \n — line boundary
                if isDiscardingOversizeLine {
                    isDiscardingOversizeLine = false
                    droppedLineCount += 1
                    logger?.error("CAPPED_READ_PIPE: dropped line over \(maxLineBytes) bytes (total dropped: \(droppedLineCount))")
                    continue
                }
                if lineBuffer.isEmpty { continue } // wake sentinel / keepalive noise
                if lineBuffer.last == 0x0D { lineBuffer.removeLast() } // \r\n
                if let soft = softLimitBytes, lineBuffer.count > soft {
                    logger?.error("CAPPED_READ_PIPE: control line of \(lineBuffer.count) bytes exceeds the \(soft)-byte announce budget — control messages must stay tiny")
                    assertionFailure("Announce-channel message exceeded PIPE_BUF-safe budget")
                }
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                return line
            }

            if isDiscardingOversizeLine { continue }
            lineBuffer.append(byte)
            if lineBuffer.count > maxLineBytes {
                // Flip to discard mode WITHOUT buffering the rest: the
                // memory already spent is released now, the remainder of
                // the line streams straight to the floor.
                lineBuffer.removeAll(keepingCapacity: false)
                isDiscardingOversizeLine = true
            }
        }
    }

    /// See `ReadPipe.signalReaderWake()` — one sentinel newline through the
    /// keepalive FD so a cancelled consumer parked in `readLine()` gets
    /// scheduler time to observe cancellation.
    public func signalReaderWake() {
        guard let fd = keepaliveWriterFD else { return }
        var sentinel: UInt8 = 0x0A
        _ = Darwin.write(fd, &sentinel, 1)
    }

    /// See `ReadPipe.close()` — callers MUST cancel + wake + await their
    /// reader Task first or this deadlocks against dispatch_io.
    public func close() async {
        byteIterator = nil
        if let fd = keepaliveWriterFD {
            Darwin.close(fd)
            keepaliveWriterFD = nil
        }
        try? fileHandle?.close()
        fileHandle = nil
    }

    private static func isFIFO(_ path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFIFO
    }
}
