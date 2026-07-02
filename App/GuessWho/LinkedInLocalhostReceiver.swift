import Foundation
import Network
import GuessWhoLogging

/// Loopback-only HTTP listener that receives the LinkedIn handoff payload from
/// the Chrome/Brave extension (`App/GuessWhoChrome`).
///
/// Chromium has no Safari-style containing-app native handler and no App Group,
/// so the Chrome extension delivers its payload as a
/// `POST http://127.0.0.1:<port>/handoff` instead of parking a file. This
/// listener is that endpoint. It accepts exactly one route and hands the raw
/// body to `onPayload` — decode/match/diff/confirm stay in the scene
/// delegate's `processLinkedInHandoff`, shared with the Safari path, so the two
/// transports can never diverge in behavior.
///
/// Scope and safety:
/// - **Binds 127.0.0.1 only** (`requiredLocalEndpoint` + `acceptLocalOnly`) —
///   never reachable off-machine. Requires the Catalyst
///   `com.apple.security.network.server` sandbox entitlement.
/// - **Origin-gated.** Browsers set the `Origin` header on extension fetches
///   and forbid page JS from forging it, so requiring
///   `chrome-extension://<allowed id>` shuts out drive-by web pages (a plain
///   `fetch` from a website would carry an `https://` Origin). A malicious
///   *local process* can forge any header — that's out of scope: a forged
///   payload can at worst ADD a new card, which the app immediately opens
///   on-screen in edit mode (loud, reviewable, deletable); changes to an
///   EXISTING contact still go through the user-reviewed confirm sheet. The
///   platform-sanctioned fix (Chrome native messaging, where Chrome itself
///   authenticates the extension) is unavailable to a sandboxed MAS app —
///   the host manifest can't be installed from inside the sandbox.
/// - **Bounded.** Head capped at 16 KB, body at `maxBodyBytes` (mirrors the
///   Safari path's parked-file cap), 30 s per-connection deadline. `Connection:
///   close` semantics — one request per connection, which is exactly how the
///   extension talks to it.
///
/// UIKit-free by design: everything is injected, so the class can be compiled
/// into a standalone harness and exercised with curl.
final class LinkedInLocalhostReceiver: @unchecked Sendable {

    /// Largest request head (request line + headers) we'll buffer.
    private static let maxHeadBytes = 16 * 1024

    /// How long a single connection may take end-to-end before being dropped.
    private static let connectionDeadline: TimeInterval = 30

    private static let log = GuessWhoLog.logger("app.linkedin-handoff.chrome")

    private let port: UInt16
    private let allowedOrigins: [String]
    private let maxBodyBytes: Int
    private let onPayload: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "com.milestonemade.guesswho.linkedin-localhost")

    private var listener: NWListener?
    /// Sessions retained while their connection is live (NWConnection does not
    /// retain itself). Keyed by identity; pruned in the session's completion.
    private var sessions: [ObjectIdentifier: Session] = [:]

    /// - Parameters:
    ///   - port: loopback port to bind (per-configuration:
    ///     `GUESSWHO_CHROME_HANDOFF_PORT`, Debug ≠ Release so a Debug extension
    ///     can never reach the Release app).
    ///   - allowedExtensionIDs: Chrome extension ids whose Origin may POST.
    ///     Empty allows any `chrome-extension://` origin (logged loudly) so a
    ///     misconfigured allowlist degrades diagnosably instead of dead.
    ///   - maxBodyBytes: payload cap; keep equal to the Safari parked-file cap.
    ///   - onPayload: called on the receiver's queue with the raw POST body.
    init(
        port: UInt16,
        allowedExtensionIDs: [String],
        maxBodyBytes: Int,
        onPayload: @escaping @Sendable (Data) -> Void
    ) {
        self.port = port
        self.allowedOrigins = allowedExtensionIDs.map { "chrome-extension://\($0)" }
        self.maxBodyBytes = maxBodyBytes
        self.onPayload = onPayload
    }

    func start() {
        queue.async { [self] in startOnQueue() }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.cancel() }
            sessions.removeAll()
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Self.log.error("invalid port \(port) — receiver not started")
            return
        }
        let params = NWParameters.tcp
        // Loopback-only, twice over: bind the local endpoint to 127.0.0.1 and
        // refuse non-local peers.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            Self.log.error("listener create failed on 127.0.0.1:\(port): \(error.localizedDescription)")
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Self.log.notice("listening on 127.0.0.1:\(self.port) (allowed origins: \(self.allowedOrigins.isEmpty ? "ANY chrome-extension://" : self.allowedOrigins.joined(separator: ",")))")
            case .failed(let error):
                // Most likely the port is already bound (a second app copy —
                // e.g. a worktree build — or an unrelated process). The Safari
                // handoff path is unaffected; only the Chrome transport is down.
                Self.log.error("listener failed on 127.0.0.1:\(self.port): \(error.localizedDescription) — Chrome handoff unavailable")
            case .cancelled:
                Self.log.notice("listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(
            connection: connection,
            allowedOrigins: allowedOrigins,
            maxBodyBytes: maxBodyBytes,
            onPayload: onPayload
        )
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onFinish = { [weak self] in
            guard let self else { return }
            self.queue.async { self.sessions[key] = nil }
        }
        queue.asyncAfter(deadline: .now() + Self.connectionDeadline) { [weak session] in
            session?.deadlineExpired()
        }
        session.start(on: queue)
    }

    // MARK: - One HTTP exchange

    /// Reads one HTTP request, writes one response, closes. Deliberately a
    /// minimal HTTP/1.1 subset: the only client is our extension's `fetch`
    /// (plus its possible CORS/Private-Network-Access preflight), not general
    /// browsers or keep-alive clients.
    ///
    /// `@unchecked Sendable` because NWConnection's handlers are `@Sendable`:
    /// safety comes from queue confinement — every mutation (buffer, head,
    /// responded, finished) happens on the receiver's single serial queue
    /// (`connection.start(queue:)`, the deadline `asyncAfter`, and `onFinish`
    /// all use it).
    private final class Session: @unchecked Sendable {
        private let connection: NWConnection
        private let allowedOrigins: [String]
        private let maxBodyBytes: Int
        private let onPayload: @Sendable (Data) -> Void
        var onFinish: (() -> Void)?

        private var buffer = Data()
        /// Set once the head is parsed; nil while still reading headers.
        private var head: Head?
        /// True once a response has been queued — every later buffer change is
        /// ignored (one request, one response, close).
        private var responded = false
        private var finished = false

        private struct Head {
            let method: String
            let path: String
            let origin: String?
            let contentLength: Int?
            /// Offset in `buffer` where the body starts.
            let bodyStart: Int
        }

        init(
            connection: NWConnection,
            allowedOrigins: [String],
            maxBodyBytes: Int,
            onPayload: @escaping @Sendable (Data) -> Void
        ) {
            self.connection = connection
            self.allowedOrigins = allowedOrigins
            self.maxBodyBytes = maxBodyBytes
            self.onPayload = onPayload
        }

        func start(on queue: DispatchQueue) {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.finish()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveMore()
        }

        func cancel() {
            connection.cancel()
        }

        func deadlineExpired() {
            guard !finished else { return }
            LinkedInLocalhostReceiver.log.error("connection deadline expired — dropping")
            connection.cancel()
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            onFinish?()
        }

        private func receiveMore() {
            guard !finished else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.advance()
                }
                if error != nil || isComplete {
                    if !self.responded {
                        // Peer went away before a full request arrived.
                        self.connection.cancel()
                    }
                    return
                }
                self.receiveMore()
            }
        }

        /// Drive the parse forward with whatever is buffered. No-op once a
        /// response is queued (late body bytes of a rejected POST just drain).
        private func advance() {
            guard !responded else { return }
            if head == nil {
                guard let parsed = parseHeadIfComplete() else { return }
                head = parsed
                route(parsed)
                return
            }
            if let head, let length = head.contentLength {
                deliverIfBodyComplete(head: head, contentLength: length)
            }
        }

        /// Parses the request head once `\r\n\r\n` is buffered. Responds and
        /// closes on malformed/oversized heads (returning nil in those cases —
        /// `responded` then keeps the session inert until the close lands).
        private func parseHeadIfComplete() -> Head? {
            let separator = Data("\r\n\r\n".utf8)
            guard let separatorRange = buffer.range(of: separator) else {
                if buffer.count > LinkedInLocalhostReceiver.maxHeadBytes {
                    respond(status: "431 Request Header Fields Too Large", origin: nil)
                }
                return nil
            }
            guard let headText = String(data: buffer[..<separatorRange.lowerBound], encoding: .utf8) else {
                respond(status: "400 Bad Request", origin: nil)
                return nil
            }
            var lines = headText.components(separatedBy: "\r\n")
            let requestParts = lines.removeFirst().split(separator: " ")
            guard requestParts.count == 3 else {
                respond(status: "400 Bad Request", origin: nil)
                return nil
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            // Path only — the extension never sends a query, but tolerate one.
            let target = String(requestParts[1])
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
            return Head(
                method: String(requestParts[0]),
                path: path,
                origin: headers["origin"],
                contentLength: headers["content-length"].flatMap(Int.init),
                bodyStart: buffer.distance(from: buffer.startIndex, to: separatorRange.upperBound)
            )
        }

        private func route(_ head: Head) {
            guard head.path == "/handoff" else {
                respond(status: "404 Not Found", origin: nil)
                return
            }
            // CORS / Private-Network-Access preflight. The extension's fetch
            // usually skips this (host_permissions grant it cross-origin
            // access), but Chromium's local-network rules have shifted release
            // to release — answering the preflight is cheap insurance.
            if head.method == "OPTIONS" {
                respond(status: "204 No Content", origin: allowedOrigin(head))
                return
            }
            guard head.method == "POST" else {
                respond(status: "405 Method Not Allowed", origin: nil)
                return
            }
            guard let origin = allowedOrigin(head) else {
                LinkedInLocalhostReceiver.log.error("rejected POST: origin \(head.origin ?? "<none>") not allowed")
                respond(status: "403 Forbidden", origin: nil)
                return
            }
            guard let contentLength = head.contentLength else {
                respond(status: "411 Length Required", origin: origin)
                return
            }
            // A negative length would sail through the cap below and trap in
            // deliverIfBodyComplete's index arithmetic — a hostile local
            // process could crash the app with one request. Reject it.
            guard contentLength >= 0 else {
                respond(status: "400 Bad Request", origin: origin)
                return
            }
            guard contentLength <= maxBodyBytes else {
                LinkedInLocalhostReceiver.log.error("rejected POST: body \(contentLength)B > cap \(maxBodyBytes)B")
                respond(status: "413 Content Too Large", origin: origin)
                return
            }
            deliverIfBodyComplete(head: head, contentLength: contentLength)
        }

        private func deliverIfBodyComplete(head: Head, contentLength: Int) {
            guard buffer.count - head.bodyStart >= contentLength else { return }
            let start = buffer.index(buffer.startIndex, offsetBy: head.bodyStart)
            let end = buffer.index(start, offsetBy: contentLength)
            let body = Data(buffer[start..<end])
            LinkedInLocalhostReceiver.log.notice("handoff received: \(body.count)B from \(head.origin ?? "<no origin>")")
            onPayload(body)
            respond(status: "200 OK", body: "{\"received\":true}", origin: allowedOrigin(head))
        }

        /// The request's Origin if it may talk to us, else nil. Empty allowlist
        /// admits any `chrome-extension://` origin (pre-pinning fallback).
        private func allowedOrigin(_ head: Head) -> String? {
            guard let origin = head.origin else { return nil }
            if allowedOrigins.isEmpty {
                return origin.hasPrefix("chrome-extension://") ? origin : nil
            }
            return allowedOrigins.contains(origin) ? origin : nil
        }

        private func respond(status: String, body: String = "", origin: String?) {
            guard !responded else { return }
            responded = true
            let bodyData = Data(body.utf8)
            var head = "HTTP/1.1 \(status)\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(bodyData.count)\r\n"
            head += "Connection: close\r\n"
            if let origin {
                head += "Access-Control-Allow-Origin: \(origin)\r\n"
                head += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
                head += "Access-Control-Allow-Headers: Content-Type\r\n"
                // Pre-standard PNA header; harmless where unsupported.
                head += "Access-Control-Allow-Private-Network: true\r\n"
                head += "Access-Control-Max-Age: 600\r\n"
            }
            head += "\r\n"
            var response = Data(head.utf8)
            response.append(bodyData)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }
}
