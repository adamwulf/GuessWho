import Foundation
import Darwin
import EasyMacMCP
import GuessWhoMCPWire
import Logging

/// Connection failures a relay caller can act on. `description` values are
/// agent-facing (they end up in tool results), so they use only the plain
/// wire vocabulary.
public enum RelayConnectionError: Error, CustomStringConvertible {
    /// The app isn't running (announce-channel probe failed with ENXIO —
    /// nothing holds the reader end). Only valid as a verdict on the
    /// ANNOUNCE channel, which the app pre-opens at listen time.
    case hostNotRunning
    /// The app is running but the session handshake didn't complete
    /// (`ready` timed out) — a distinct, diagnosable state, NOT the same
    /// as "not running".
    case hostNotReady
    /// A response didn't arrive within the tool's timeout.
    case timedOut
    /// Local pipe plumbing failed in a way retry won't fix.
    case transport(Error)

    public var description: String {
        switch self {
        case .hostNotRunning: return WireErrorMessage.notRunning
        case .hostNotReady: return WireErrorMessage.hostNotReady
        case .timedOut: return WireErrorMessage.timedOut
        case .transport: return WireErrorMessage.hostNotReady
        }
    }
}

/// The helper side of the relay channel: announce → await `ready` → open
/// the per-helper request pipe → send tool calls; reconnect when the app
/// goes away and comes back.
///
/// Reconnect design (plans/cli-mcp.md): an app quit delivers NO signal to
/// a parked helper (the response reader holds its own keepalive FD), so
/// host death is discovered on the next write failure — at which point we
/// close both pipes, re-probe the announce channel (ENXIO ⇒ "app not
/// running", surfaced upward), and re-run the initialize/ready handshake
/// before retrying once. That same path is what makes the app's launch
/// sweep safe for helpers that outlive an app restart.
public actor RelayConnection {
    public nonisolated let helperId: String
    private let container: URL
    private let logger: Logger?
    private let readyTimeout: TimeInterval

    private var announcePipe: ChunkedWritePipe?
    private var requestPipe: ChunkedWritePipe?
    private var responseRouter: RelayResponseRouter?
    private var isConnected = false
    private var pingTask: Task<Void, Never>?
    /// Keep-fresh interval for the app-side liveness clock; well under the
    /// host's reap timeout.
    private let pingInterval: TimeInterval

    public init(
        helperId: String,
        container: URL,
        logger: Logger? = nil,
        readyTimeout: TimeInterval = 5,
        pingInterval: TimeInterval = 45
    ) {
        self.helperId = helperId
        self.container = container
        self.logger = logger
        self.readyTimeout = readyTimeout
        self.pingInterval = pingInterval
    }

    public var connected: Bool { isConnected }

    // MARK: - Probe

    /// ENXIO fast-fail probe, scoped to the ANNOUNCE channel only: the app
    /// pre-opens that reader at listen time, so `open(O_WRONLY|O_NONBLOCK)`
    /// failing with ENXIO there means "app not listening". (The same probe
    /// on a per-helper pipe would misread the post-initialize setup window
    /// as "not running".)
    public func probeHostAvailable() -> Bool {
        let path = WireEnvironment.announcePipePath(container: container).path
        let fd = Darwin.open(path, O_WRONLY | O_NONBLOCK, 0)
        if fd >= 0 {
            Darwin.close(fd)
            return true
        }
        return false
    }

    // MARK: - Connect / disconnect

    public func connect() async throws {
        guard !isConnected else { return }

        guard probeHostAvailable() else { throw RelayConnectionError.hostNotRunning }

        do {
            // Response pipe FIRST: our reader must exist before the app
            // tries to open its writer during initialize handling.
            let responseURL = WireEnvironment.responsePipePath(container: container, helperId: helperId)
            let router = try RelayResponseRouter(url: responseURL, logger: logger)
            try await router.startReading()
            responseRouter = router

            let announceURL = WireEnvironment.announcePipePath(container: container)
            let announce = try ChunkedWritePipe(url: announceURL, logger: logger)
            try await announce.open()
            announcePipe = announce
        } catch {
            await closePipes()
            throw RelayConnectionError.transport(error)
        }

        // Handshake: initialize on the announce channel, then await the
        // `ready` echo through the ordinary response-matching path. Only
        // after `ready` does the request pipe exist host-side (Guard 2).
        let messageId = UUID().uuidString
        do {
            try await announcePipe?.send(
                WireRequest.initialize(helperId: helperId, messageId: messageId))
        } catch {
            await closePipes()
            throw RelayConnectionError.transport(error)
        }

        do {
            _ = try await responseRouter?.waitForResponse(
                helperId: helperId, messageId: messageId, timeout: readyTimeout)
        } catch {
            await closePipes()
            // Announce write succeeded but no ready: app running-but-wedged
            // (or it died in the window). Distinct verdict from ENXIO.
            throw RelayConnectionError.hostNotReady
        }

        do {
            let requestURL = WireEnvironment.requestPipePath(container: container, helperId: helperId)
            let request = try ChunkedWritePipe(url: requestURL, logger: logger)
            try await request.open()
            requestPipe = request
        } catch {
            await closePipes()
            throw RelayConnectionError.hostNotReady
        }

        isConnected = true
        startPinging()
        logger?.info("RELAY: connected as \(helperId)")
    }

    public func disconnect() async {
        pingTask?.cancel()
        pingTask = nil
        if isConnected {
            // Best-effort: a dead host can't read this, and that's fine.
            try? await announcePipe?.send(WireRequest.deinitialize(helperId: helperId))
        }
        await closePipes()
        isConnected = false
    }

    private func closePipes() async {
        if let router = responseRouter {
            await router.stopReading() // awaited: cancel → wake → await → close
        }
        responseRouter = nil
        if let request = requestPipe {
            await request.close()
        }
        requestPipe = nil
        if let announce = announcePipe {
            await announce.close()
        }
        announcePipe = nil
        isConnected = false
    }

    // MARK: - Requests

    /// Send a tool call and await its response. On a write failure the
    /// host is assumed restarted: reconnect (full handshake) and retry the
    /// send ONCE. Read tools are idempotent, so the single retry is safe.
    public func send(_ request: WireRequest, timeout: TimeInterval) async throws -> WireResponse {
        if !isConnected {
            try await connect()
        }
        guard let pipe = requestPipe else {
            throw RelayConnectionError.hostNotReady
        }

        do {
            try await pipe.send(request)
        } catch {
            logger?.info("RELAY: request write failed (\(error)); attempting reconnect")
            await closePipes()
            try await connect()
            guard let retryPipe = requestPipe else {
                throw RelayConnectionError.hostNotReady
            }
            do {
                try await retryPipe.send(request)
            } catch {
                await closePipes()
                throw RelayConnectionError.transport(error)
            }
        }

        // Re-read the router AFTER any reconnect — it is rebuilt with the
        // pipes.
        guard let router = responseRouter else {
            throw RelayConnectionError.hostNotReady
        }
        do {
            return try await router.waitForResponse(
                helperId: helperId, messageId: request.messageId, timeout: timeout)
        } catch let error as ResponseError where error == .timeout {
            throw RelayConnectionError.timedOut
        } catch let error as RelayConnectionError {
            throw error
        } catch {
            throw RelayConnectionError.transport(error)
        }
    }

    // MARK: - Liveness

    /// Periodic ping over the request pipe: keeps the app-side last-seen
    /// clock fresh so an idle helper isn't reaped, and doubles as our own
    /// host-death detector (a failed ping triggers the reconnect path).
    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { [weak self, pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.sendPing()
            }
        }
    }

    private func sendPing() async {
        guard isConnected else { return }
        let ping = WireRequest.ping(helperId: helperId, messageId: UUID().uuidString)
        do {
            _ = try await send(ping, timeout: readyTimeout)
        } catch {
            logger?.info("RELAY: ping failed (\(error)); session will reconnect on next use")
        }
    }
}
