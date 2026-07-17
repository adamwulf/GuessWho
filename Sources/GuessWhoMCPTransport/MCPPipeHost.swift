import Foundation
import Darwin
import EasyMacMCP
import GuessWhoMCPWire
import Logging

/// The app-side end of the relay channel (plans/cli-mcp.md Phase 1).
///
/// Topology — the deliberate change vs. the inherited `EasyMCPHost`:
///
/// * The central FIFO is ANNOUNCE-ONLY: it carries `initialize` /
///   `deinitialize` and nothing else (Guard 1). Tool calls arrive on a
///   dedicated request FIFO per helper id, so every data pipe has exactly
///   one writer and interleaving is structurally impossible at any size
///   (PIPE_BUF on Darwin is 512 bytes; the shared-pipe design tears above
///   it).
/// * `initialize` handling creates BOTH per-helper pipes, then sends a
///   `ready` acknowledgment on the helper's response pipe echoing the
///   initialize message id (Guard 2). The helper must not open its request
///   pipe before `ready` — the host only finishes creating it here.
/// * Teardown awaits each reader's cancel → wake → await → close sequence
///   individually — the base class's fire-and-forget detached closes are
///   the documented dispatch_io deadlock we are NOT copying.
/// * Liveness reaping is REQUIRED, not optional: a SIGKILLed helper never
///   sends `deinitialize`, and reader EOF is not a death signal (the read
///   pipes hold their own keepalive writer FD). Any traffic on a helper's
///   request pipe bumps its last-seen clock; helpers ping when idle; the
///   reaper tears down sessions that go quiet.
/// * The launch sweep deletes orphaned per-helper FIFO files from previous
///   runs. It is safe ONLY because live helpers re-announce (and re-create
///   their FIFOs) on their next write failure — see `RelayConnection`.
public actor MCPPipeHost {
    /// Handles one decoded tool request, returning the response to write
    /// back (nil = nothing to send). Runs OFF the pipe-reading task.
    public typealias Handler = @Sendable (WireRequest) async -> WireResponse?

    private struct Session {
        let requestPipe: WireRequestReader
        let responsePipe: HostResponsePipe<WireResponse>
        let requestFIFOURL: URL
        var lastSeen: Date
    }

    private let container: URL
    private let handler: Handler
    private let logger: Logger?
    private let livenessTimeout: TimeInterval
    private let reapInterval: TimeInterval

    private var announcePipe: WireRequestReader?
    private var sessions: [String: Session] = [:]
    private var reaper: Task<Void, Never>?
    private var isListening = false

    public init(
        container: URL,
        handler: @escaping Handler,
        logger: Logger? = nil,
        livenessTimeout: TimeInterval = 180,
        reapInterval: TimeInterval = 30
    ) {
        self.container = container
        self.handler = handler
        self.logger = logger
        self.livenessTimeout = livenessTimeout
        self.reapInterval = reapInterval
    }

    /// Number of live helper sessions (test seam).
    public var sessionCount: Int { sessions.count }

    // MARK: - Lifecycle

    public func startListening() async throws {
        guard !isListening else { return }
        isListening = true

        sweepOrphanedPipes()

        let announceURL = WireEnvironment.announcePipePath(container: container)
        let readPipe = try CappedLineReadPipe(
            url: announceURL,
            maxLineBytes: WireEnvironment.maxRequestLineBytes,
            softLimitBytes: WireEnvironment.darwinPipeBuf,
            logger: logger)
        let announce = WireRequestReader(readPipe: readPipe, logger: logger)
        try await announce.open()
        announcePipe = announce

        await announce.startReading { [weak self] request in
            await self?.handleAnnounce(request)
        }

        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.reapInterval ?? 30) * 1_000_000_000))
                await self?.reapDeadSessions()
            }
        }
        logger?.info("PIPE_HOST: listening on \(announceURL.path)")
    }

    public func stopListening() async {
        guard isListening else { return }
        isListening = false
        reaper?.cancel()
        reaper = nil

        // Await EVERY close individually — announce reader first so no new
        // sessions arrive, then each per-helper reader/writer pair.
        if let announce = announcePipe {
            await announce.close()
            announcePipe = nil
        }
        for helperId in Array(sessions.keys) {
            await teardownSession(helperId: helperId)
        }
        logger?.info("PIPE_HOST: stopped")
    }

    // MARK: - Announce channel

    private func handleAnnounce(_ request: WireRequest) async {
        // Guard 1: the announce channel carries ONLY init/deinit. Anything
        // else here is a misrouted client or a design regression.
        if request.isInitialize {
            await setupSession(helperId: request.helperId, readyMessageId: request.messageId)
        } else if request.isDeinitialize {
            await teardownSession(helperId: request.helperId)
        } else {
            logger?.error("PIPE_HOST: non-lifecycle message on the announce channel from \(request.helperId) — ignored")
            assertionFailure("Announce channel must carry only initialize/deinitialize")
        }
    }

    private func setupSession(helperId: String, readyMessageId: String) async {
        // Re-announce from a known helper (helper restarted, or reconnect
        // after we restarted): tear the old pipes down first, awaited, then
        // build fresh ones. Handles minted by the dispatch layer survive —
        // they are keyed on the host run, not the helper session.
        if sessions[helperId] != nil {
            logger?.info("PIPE_HOST: re-announce from \(helperId); rebuilding session")
            await teardownSession(helperId: helperId)
        }

        let responseURL = WireEnvironment.responsePipePath(container: container, helperId: helperId)
        let requestURL = WireEnvironment.requestPipePath(container: container, helperId: helperId)

        var openedResponsePipe: HostResponsePipe<WireResponse>?
        var openedRequestPipe: WireRequestReader?
        do {
            // The helper creates + opens its response reader BEFORE sending
            // initialize, so opening our writer here succeeds; failure means
            // the helper died in the announce window — abort, no session.
            let writePipe = try ChunkedWritePipe(url: responseURL, logger: logger)
            try await writePipe.open()
            let responsePipe = HostResponsePipe<WireResponse>(
                helperId: helperId, writePipe: writePipe, logger: logger)
            openedResponsePipe = responsePipe

            let readPipe = try CappedLineReadPipe(
                url: requestURL,
                maxLineBytes: WireEnvironment.maxRequestLineBytes,
                logger: logger)
            let requestPipe = WireRequestReader(readPipe: readPipe, logger: logger)
            try await requestPipe.open()
            openedRequestPipe = requestPipe

            sessions[helperId] = Session(
                requestPipe: requestPipe,
                responsePipe: responsePipe,
                requestFIFOURL: requestURL,
                lastSeen: Date())

            await requestPipe.startReading { [weak self] request in
                await self?.handleHelperRequest(request)
            }

            // Guard 2: the ready-ack. Echoes the initialize message id so
            // the helper awaits it through its ordinary response matching,
            // and only then opens the request pipe we just created.
            try await responsePipe.sendResponse(
                .ready(helperId: helperId, messageId: readyMessageId))
            logger?.info("PIPE_HOST: session up for \(helperId)")
        } catch {
            logger?.error("PIPE_HOST: session setup failed for \(helperId): \(error)")
            // Close whatever half-opened before the failure; the session was
            // never registered (or is removed) so nothing else references it.
            sessions.removeValue(forKey: helperId)
            if let requestPipe = openedRequestPipe { await requestPipe.close() }
            if let responsePipe = openedResponsePipe { await responsePipe.close() }
        }
    }

    private func teardownSession(helperId: String) async {
        guard let session = sessions.removeValue(forKey: helperId) else { return }
        // WireRequestReader.close() runs the full cancel → wake → await →
        // close sequence internally; awaiting it here (per pipe, never a
        // detached Task) is the deadlock fix.
        await session.requestPipe.close()
        await session.responsePipe.close()
        // The request FIFO is ours (created in setup); remove the file so
        // dead helpers don't accumulate FIFOs across a long run. The
        // response FIFO is the helper's to recreate on reconnect.
        try? FileManager.default.removeItem(at: session.requestFIFOURL)
        logger?.info("PIPE_HOST: session down for \(helperId)")
    }

    // MARK: - Per-helper requests

    private func handleHelperRequest(_ request: WireRequest) async {
        let helperId = request.helperId
        guard sessions[helperId] != nil else {
            logger?.error("PIPE_HOST: request from unknown session \(helperId) — dropped")
            return
        }
        sessions[helperId]?.lastSeen = Date()

        if request.isPing {
            // Liveness echo: same `ready` shape, echoing the ping's message
            // id — "your session is live".
            await send(.ready(helperId: helperId, messageId: request.messageId), to: helperId)
            return
        }
        if request.isInitialize || request.isDeinitialize {
            logger?.error("PIPE_HOST: lifecycle message on a data pipe from \(helperId) — ignored")
            return
        }
        if let response = await handler(request) {
            await send(response, to: helperId)
        }
    }

    private func send(_ response: WireResponse, to helperId: String) async {
        guard let session = sessions[helperId] else {
            logger?.error("PIPE_HOST: no session to answer \(helperId)")
            return
        }
        do {
            try await session.responsePipe.sendResponse(response)
        } catch {
            logger?.error("PIPE_HOST: response write failed for \(helperId): \(error)")
        }
    }

    // MARK: - Reaping & sweeping

    private func reapDeadSessions() async {
        let cutoff = Date().addingTimeInterval(-livenessTimeout)
        let dead = sessions.filter { $0.value.lastSeen < cutoff }.map(\.key)
        for helperId in dead {
            logger?.info("PIPE_HOST: reaping quiet session \(helperId)")
            await teardownSession(helperId: helperId)
        }
    }

    /// Remove per-helper FIFO files left by previous runs. Runs before the
    /// announce pipe opens, so `sessions` is empty: every matching file is
    /// an orphan OR belongs to a still-alive helper from before our
    /// restart — and that helper's next write fails, triggering its
    /// re-announce, which recreates what it needs. Never assume "a fresh
    /// app owns no helpers" beyond that recovery path.
    private func sweepOrphanedPipes() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: container.path) else { return }
        for name in names {
            guard WireEnvironment.perHelperPipePrefixes.contains(where: { name.hasPrefix($0) }) else {
                continue
            }
            let url = container.appendingPathComponent(name)
            try? fm.removeItem(at: url)
            logger?.info("PIPE_HOST: swept orphaned FIFO \(name)")
        }
    }
}
