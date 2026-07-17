import Foundation
import Darwin
import EasyMacMCP
import GuessWhoMCPWire
import Logging

/// FIFO writer that never issues a single `write(2)` larger than
/// `maxChunkBytes`.
///
/// ## Why chunked (measured, not theoretical)
///
/// On macOS a single blocking `write(2)` of more than ~4KB to a FIFO whose
/// reader is parked on a kqueue/dispatch read source produces NO readable
/// events until the whole write completes — and the write can't complete
/// because the reader never drains: a kernel-level mutual wedge (see
/// `ReadPipeDeliveryTests.testLargeLineSizeThreshold`; ≤4KB writes deliver,
/// 8KB+ never do). The inherited `WritePipe` hands the entire payload to
/// one `FileHandle` write, so ANY payload above a few KB wedges the
/// channel. Splitting into ≤4KB writes keeps every kernel transfer below
/// the hazard and lets the reader drain between chunks.
///
/// Chunking does NOT re-open the interleaving hazard the per-helper pipes
/// exist to prevent: each data pipe has exactly ONE writing process, and
/// within this writer whole messages are serialized (concurrent `write`
/// calls queue; chunks of two messages never interleave). On the shared
/// announce channel every control message is ≤ PIPE_BUF (512B) and goes
/// out in a single atomic write.
///
/// The FD stays `O_NONBLOCK`: when the pipe is full the writer awaits a
/// `DispatchSourceWrite` writability event instead of blocking a Swift
/// concurrency thread.
public actor ChunkedWritePipe: PipeWritable {
    /// Largest single write(2). Keep at or below 4096: 8192 is already
    /// inside the measured wedge zone.
    public static let maxChunkBytes = 4096

    private let fileURL: URL
    private let logger: Logger?
    private var fd: Int32 = -1
    private var source: DispatchSourceWrite?
    private let writableSignal = PipeSignal()
    /// Serialization chain: concurrent write() calls append here so whole
    /// messages go out back-to-back even though the actor is re-entrant
    /// across the writability awaits.
    private var lastWrite: Task<Void, Error>?

    public init(url: URL, logger: Logger? = nil) throws {
        guard url.isFileURL else { throw WritePipeError.invalidURL }
        self.fileURL = url
        self.logger = logger

        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            if !Self.isFIFO(path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    throw WritePipeError.pipeAlreadyExists
                }
                guard mkfifo(path, 0o600) == 0 else {
                    throw WritePipeError.failedToCreatePipe(String(cString: strerror(errno)))
                }
            }
        } else {
            guard mkfifo(path, 0o600) == 0 else {
                throw WritePipeError.failedToCreatePipe(String(cString: strerror(errno)))
            }
        }
        guard Self.isFIFO(path) else { throw WritePipeError.notAPipe }
    }

    deinit {
        if let source {
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// Opens write-only, non-blocking. Fails with `openFailed` (ENXIO)
    /// when nothing holds the read end — the same no-reader probe
    /// semantics the inherited WritePipe has, which the connect flow
    /// relies on.
    public func open() async throws {
        guard fd < 0 else { return }
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw WritePipeError.pipeDoesNotExist
        }
        guard Self.isFIFO(path) else { throw WritePipeError.notAPipe }

        let opened = Darwin.open(path, O_WRONLY | O_NONBLOCK, 0)
        guard opened != -1 else {
            throw WritePipeError.openFailed(String(cString: strerror(errno)))
        }
        fd = opened

        let queue = DispatchQueue(label: "com.milestonemade.guesswho.mcp.pipe-write")
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: opened, queue: queue)
        let signal = writableSignal
        writeSource.setEventHandler {
            signal.signal()
        }
        writeSource.setCancelHandler {
            Darwin.close(opened)
            signal.signal()
        }
        writeSource.resume()
        // The source fires only on future writability EDGES; the pipe is
        // almost certainly writable right now, so pre-arm one pass.
        signal.signal()
        source = writeSource
    }

    public func write(_ data: Data) async throws {
        let previous = lastWrite
        let task = Task {
            _ = try? await previous?.value
            try await self.performWrite(data)
        }
        lastWrite = task
        try await task.value
    }

    /// Encode one wire message and send it as a single newline-terminated
    /// JSON line (the only sanctioned framing — JSONEncoder escapes any
    /// embedded newlines).
    public func send<Message: Encodable>(_ message: Message) async throws {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try await write(data)
    }

    public func write(_ message: String) async throws {
        try await write(Data(message.utf8))
    }

    public func close() async {
        if let source {
            source.cancel()
            self.source = nil
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        fd = -1
        writableSignal.signal()
        lastWrite = nil
    }

    private func performWrite(_ data: Data) async throws {
        var offset = 0
        let total = data.count
        while offset < total {
            if Task.isCancelled { throw CancellationError() }
            guard fd >= 0 else {
                throw WritePipeError.pipeNotOpened
            }
            let chunkEnd = min(offset + Self.maxChunkBytes, total)
            let written = data.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), chunkEnd - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 { continue }
            let code = errno
            switch code {
            case EAGAIN, EWOULDBLOCK:
                await writableSignal.wait()
            case EINTR:
                continue
            default:
                // EPIPE lands here (SIGPIPE is ignored process-wide by the
                // relay): the read end is gone — the reconnect path's cue.
                throw WritePipeError.writeError(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
            }
        }
    }

    private static func isFIFO(_ path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFIFO
    }
}
