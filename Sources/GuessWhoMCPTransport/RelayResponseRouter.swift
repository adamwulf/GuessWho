import Foundation
import EasyMacMCP
import GuessWhoMCPWire
import Logging

/// Matches responses read off the helper's response pipe to awaiting
/// requests by (helperId, messageId) — a local mirror of EasyMacMCP's
/// `ResponseManager`, reading through `CappedLineReadPipe` instead of
/// `FileHandle.bytes` (see that type's docs for why the platform reader
/// can't be trusted with several parked FIFO reads per process — the
/// in-process transport tests park host + helper readers together).
public actor RelayResponseRouter {
    private let readPipe: CappedLineReadPipe
    private let logger: Logger?
    private var pending: [String: CheckedContinuation<WireResponse, Error>] = [:]
    /// Responses that arrived before their waiter registered. The caller
    /// awaits only AFTER its request write completes, and a fast host can
    /// answer inside that window — dropping those as "unsolicited" turns a
    /// won race into a spurious timeout. Bounded FIFO so a hostile peer
    /// can't grow it.
    private var arrivedEarly: [String: WireResponse] = [:]
    private var arrivedEarlyOrder: [String] = []
    private static let arrivedEarlyCap = 64
    private var readerTask: Task<Void, Never>?

    public init(url: URL, logger: Logger? = nil) throws {
        self.readPipe = try CappedLineReadPipe(
            url: url,
            maxLineBytes: WireEnvironment.maxRequestLineBytes,
            logger: logger)
        self.logger = logger
    }

    public func startReading() async throws {
        try await readPipe.open()
        readerTask?.cancel()
        readerTask = Task {
            do {
                while !Task.isCancelled {
                    guard let line = try await readPipe.readLine() else { break }
                    guard let response = try? JSONDecoder().decode(
                        WireResponse.self, from: Data(line.utf8))
                    else {
                        logger?.error("RESPONSE_ROUTER: undecodable response line (\(line.utf8.count) bytes)")
                        continue
                    }
                    deliver(response)
                }
            } catch is CancellationError {
                logger?.info("RESPONSE_ROUTER: reader exited on cancellation")
            } catch {
                logger?.error("RESPONSE_ROUTER: reader error: \(error)")
            }
        }
    }

    /// Cancel → wake → await → close, per pipe — the shared shutdown
    /// sequence. Pending waiters are failed so callers don't sit out their
    /// full timeout against a closed pipe.
    public func stopReading() async {
        let task = readerTask
        readerTask = nil
        task?.cancel()
        readPipe.signalReaderWake()
        _ = await task?.value
        await readPipe.close()
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: ResponseError.requestCancelled)
        }
    }

    public func waitForResponse(
        helperId: String, messageId: String, timeout: TimeInterval
    ) async throws -> WireResponse {
        let key = "\(helperId):\(messageId)"
        if let early = arrivedEarly.removeValue(forKey: key) {
            arrivedEarlyOrder.removeAll { $0 == key }
            return early
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.timeOut(key: key)
            }
        }
    }

    private func deliver(_ response: WireResponse) {
        let key = "\(response.helperId):\(response.messageId)"
        if let continuation = pending.removeValue(forKey: key) {
            continuation.resume(returning: response)
            return
        }
        // Won the race against the waiter — hold it briefly.
        arrivedEarly[key] = response
        arrivedEarlyOrder.append(key)
        if arrivedEarlyOrder.count > Self.arrivedEarlyCap {
            let evicted = arrivedEarlyOrder.removeFirst()
            arrivedEarly.removeValue(forKey: evicted)
        }
    }

    private func timeOut(key: String) {
        guard let continuation = pending.removeValue(forKey: key) else { return }
        continuation.resume(throwing: ResponseError.timeout)
    }
}
