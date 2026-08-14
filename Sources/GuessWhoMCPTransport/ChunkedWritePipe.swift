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
    /// When set, any single message larger than this logs loudly and
    /// debug-asserts BEFORE it is written. Set to PIPE_BUF on the shared
    /// announce channel (Guard 1): a control frame above the atomic-write
    /// ceiling would silently re-arm the interleaving bug the per-helper
    /// pipes exist to prevent.
    private let softLimitBytes: Int?
    private var fd: Int32 = -1
    private var source: DispatchSourceWrite?
    /// Write-source arm state. `false` ⇒ the source is inactive/suspended
    /// (idle); `true` ⇒ resumed (active). A `DispatchSourceWrite` is
    /// level-triggered on writability, so an always-armed source on an idle
    /// FIFO busy-loops — arm it only while a writer is parked on `EAGAIN`.
    private var isSourceArmed = false
    /// One-shot latch: set by `close()`, checked by `open()`. Once closed, the
    /// instance is permanently unusable. Every production caller builds a fresh
    /// pipe on reconnect, so rejecting reopen closes the close/reopen
    /// generation race without breaking any caller.
    private var isClosed = false
    private let writableSignal = PipeSignal()
    /// Test-only observation seam: invoked once per write-source event-handler
    /// entry (never from the cancel handler or a manual `signal()`). Nil in
    /// production, so the optional call is behavior-neutral. Set via
    /// `_setOnSourceFire(_:)` before `open()`; `open()` snapshots it into a
    /// local so the dispatch handler never captures the actor.
    private var onSourceFire: (@Sendable () -> Void)?
    /// Serialization chain: concurrent write() calls append here so whole
    /// messages go out back-to-back even though the actor is re-entrant
    /// across the writability awaits.
    private var lastWrite: Task<Void, Error>?

    public init(url: URL, softLimitBytes: Int? = nil, logger: Logger? = nil) throws {
        guard url.isFileURL else { throw WritePipeError.invalidURL }
        self.fileURL = url
        self.softLimitBytes = softLimitBytes
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
            // Fallback for deallocate-without-close. After the gating change a
            // source at rest is inactive/suspended; resume before cancel so
            // release does not crash libdispatch and the cancel handler closes
            // the fd. (deinit has exclusive access, so reading isSourceArmed is
            // safe.)
            if !isSourceArmed { source.resume() }
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// Test-only: install the write-source fire probe. Must be called before
    /// `open()`. See `onSourceFire`. No production caller sets this.
    func _setOnSourceFire(_ probe: (@Sendable () -> Void)?) {
        onSourceFire = probe
    }

    /// Resume (activate) the write source so the FIFO becoming writable wakes a
    /// parked writer. Guarded by `isSourceArmed` so the suspend/resume count
    /// stays balanced (0 or 1). Only `performWrite`'s `EAGAIN` branch arms.
    private func armSource() {
        guard let source, !isSourceArmed else { return }
        isSourceArmed = true
        source.resume()   // resume() on an inactive source acts as activate()
    }

    /// Suspend the write source so it stops firing once no writer waits. This
    /// is what stops the idle busy-loop.
    private func disarmSource() {
        guard let source, isSourceArmed else { return }
        isSourceArmed = false
        source.suspend()
    }

    /// Opens write-only, non-blocking. Fails with `openFailed` (ENXIO)
    /// when nothing holds the read end — the same no-reader probe
    /// semantics the inherited WritePipe has, which the connect flow
    /// relies on.
    public func open() async throws {
        guard !isClosed else { throw ChunkedWritePipeError.pipeClosed }
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
        // Per-FD SIGPIPE suppression: a write(2) to a FIFO whose reader died
        // must return EPIPE (the reconnect/teardown cue), never deliver
        // SIGPIPE. This writer runs in the APP as well as the relay, and the
        // app sets no process-wide signal disposition — without this, a
        // helper dying between responses would terminate GuessWho itself.
        _ = fcntl(opened, F_SETNOSIGPIPE, 1)
        fd = opened

        let queue = DispatchQueue(label: "com.milestonemade.guesswho.mcp.pipe-write")
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: opened, queue: queue)
        let signal = writableSignal
        let onFire = onSourceFire   // local snapshot; nil in production
        writeSource.setEventHandler {
            onFire?()
            signal.signal()
        }
        writeSource.setCancelHandler {
            Darwin.close(opened)
            signal.signal()
        }
        // Do NOT resume here. A DispatchSourceWrite is level-triggered on
        // writability, and an idle FIFO is always writable, so an always-armed
        // source would fire its handler continuously and burn a core. The
        // source is created inactive and is armed (resumed) only around the
        // EAGAIN wait in performWrite(); see armSource()/disarmSource().
        source = writeSource
    }

    public func write(_ data: Data) async throws {
        if let soft = softLimitBytes, data.count > soft {
            logger?.error("CHUNKED_WRITE_PIPE: control frame of \(data.count) bytes exceeds the \(soft)-byte announce budget — control messages must stay tiny")
            assertionFailure("Announce-channel message exceeded PIPE_BUF-safe budget")
        }
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
        // One-shot first: reject any future open() before touching the source,
        // so a stale writer can never wake into a newly installed source.
        isClosed = true
        if let source {
            // A source at rest here is inactive/suspended. cancel() on such a
            // source defers its cancel handler (which closes the fd) until a
            // resume, and releasing it crashes libdispatch. Resume first so the
            // handler runs now and release is safe.
            if !isSourceArmed { source.resume(); isSourceArmed = true }
            source.cancel()
            self.source = nil
            isSourceArmed = false
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
                // The pipe is full. Arm the write source so a writability edge
                // wakes us, wait, then disarm so the source goes quiet again.
                armSource()
                await writableSignal.wait()
                disarmSource()
            case EINTR:
                continue
            default:
                // EPIPE lands here (the FD carries F_SETNOSIGPIPE, so no
                // signal is delivered in host OR relay): the read end is
                // gone — the reconnect/teardown path's cue.
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
