import Foundation
import EasyMacMCP
import GuessWhoMCPWire
import Logging

/// Continuous request reader over a `PipeReadable` — a local mirror of
/// EasyMacMCP's `HostRequestPipe` (whose members are internal to that
/// module), preserving its two load-bearing behaviors:
///
/// * Lifecycle requests (`initialize` / `deinitialize`) dispatch INLINE so
///   session setup/teardown is ordered against subsequent messages on the
///   same pipe; everything else dispatches in its own Task so parallel
///   tool calls actually run in parallel (responses match by message id).
/// * `close()` runs the full cancel → wake sentinel → await task →
///   close-pipe sequence internally — the ordering that keeps
///   `readPipe.close()` from deadlocking against dispatch_io's in-flight
///   read (see `ReadPipe.signalReaderWake()` in EasyMacMCP).
public actor WireRequestReader {
    private let readPipe: any PipeReadable
    private let logger: Logger?
    private var readingTask: Task<Void, Never>?
    private var isReading = false

    public init(readPipe: any PipeReadable, logger: Logger? = nil) {
        self.readPipe = readPipe
        self.logger = logger
    }

    public func open() async throws {
        try await readPipe.open()
    }

    /// Close the pipe, stopping any in-flight reading Task first (awaited,
    /// never fire-and-forget).
    public func close() async {
        await stopReading()
        await readPipe.close()
    }

    public func startReading(requestHandler: @Sendable @escaping (WireRequest) async -> Void) {
        guard !isReading else { return }
        isReading = true
        readingTask?.cancel()

        readingTask = Task {
            do {
                while isReading && !Task.isCancelled {
                    // nil = the pipe was closed by us (the keepalive FD
                    // suppresses external EOF) — exit rather than spin.
                    guard let line = try await readPipe.readLine() else { break }
                    guard let request = decode(line) else { continue }
                    if request.isInitialize || request.isDeinitialize {
                        await requestHandler(request)
                    } else {
                        Task { await requestHandler(request) }
                    }
                }
            } catch is CancellationError {
                logger?.info("REQUEST_READER: read loop exited on cancellation")
                isReading = false
            } catch {
                logger?.error("REQUEST_READER: read loop error: \(error)")
                isReading = false
            }
        }
    }

    private func stopReading() async {
        isReading = false
        let task = readingTask
        readingTask = nil
        task?.cancel()
        await readPipe.signalReaderWake()
        _ = await task?.value
    }

    private func decode(_ line: String) -> WireRequest? {
        do {
            return try JSONDecoder().decode(WireRequest.self, from: Data(line.utf8))
        } catch {
            // Malformed line: log and drop. Never echo the line's content
            // anywhere agent-visible.
            logger?.error("REQUEST_READER: undecodable request line (\(line.utf8.count) bytes): \(error)")
            return nil
        }
    }
}
