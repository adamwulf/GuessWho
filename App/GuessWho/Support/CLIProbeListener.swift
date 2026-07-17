#if targetEnvironment(macCatalyst)
import Foundation
import GuessWhoLogging

/// Phase 0 diagnostic hook for the embedded relay CLI (plans/cli-mcp.md).
///
/// While debug mode is on, the app creates a FIFO in the shared CLI App Group
/// container and holds a reader open on it. `guesswho-cli probe` (spawned by
/// hand or by an MCP client) opens the FIFO `O_WRONLY|O_NONBLOCK` — which
/// succeeds only because this reader exists — and writes one line; the app
/// logs it. That one logged line is the binary-checkable "connected" signal
/// for Phase 0's client-spawn exit criterion. The real announce channel /
/// per-helper pipes replace this in Phase 1.
///
/// Gated at RUNTIME by the debug-mode Settings toggle (which ships in
/// Release), deliberately NOT `#if DEBUG`: Phase 0 verifies on
/// Release/exported builds. Catalyst-only per INV-5 — iOS builds carry no
/// FIFO code and no embedded helper.
final class CLIProbeListener {
    /// Developer-facing breadcrumbs (debug-mode surface; internal vocabulary
    /// like "FIFO"/"App Group" is fine here per the CLAUDE.md carve-out).
    private static let log = GuessWhoLog.logger("cli.probe")

    /// Container-relative FIFO path. Must match `ProbeConstants
    /// .fifoRelativePath` in App/guesswho-cli/GuessWhoCLI.swift; the shared
    /// wire module takes over as the single home for pipe paths in Phase 1.
    private static let fifoRelativePath = "Diagnostics/cli-probe.fifo"

    private var fifoURL: URL?
    private var readFD: Int32 = -1
    /// Keepalive writer on our own FIFO. With only a reader open, the first
    /// probe's close() would deliver EOF and the read source would spin on
    /// zero-byte reads; holding a writer FD means read() blocks/EAGAINs
    /// instead — the same keepalive-FD pattern EasyMacMCP's ReadPipe uses.
    private var keepaliveFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pending = Data()

    var isRunning: Bool { readSource != nil }

    /// Creates the FIFO and starts logging lines written into it.
    /// Idempotent; failures are logged, never fatal (diagnostic surface).
    func start() {
        guard !isRunning else { return }

        // Log the helper's resolved location alongside the pipe bring-up —
        // the two facts a Phase 0 verification run needs together.
        Self.log.notice("cli probe listener starting", [
            "helperPath": CLIHelper.helperURL?.path ?? "<not found>"
        ])

        guard let groupID = CLIHelper.appGroupID else {
            Self.log.error("cli probe listener: GuessWhoCLIAppGroup missing from Info.plist")
            return
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID)
        else {
            Self.log.error("cli probe listener: cannot resolve App Group container", [
                "group": groupID
            ])
            return
        }

        let fifo = container.appendingPathComponent(Self.fifoRelativePath)
        do {
            try FileManager.default.createDirectory(
                at: fifo.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Self.log.error("cli probe listener: cannot create Diagnostics dir", [
                "error": "\(error)"
            ])
            return
        }

        // Recreate the FIFO from scratch: a stale regular file (or a FIFO
        // left by a crashed run) at the path would break mkfifo.
        unlink(fifo.path)
        guard mkfifo(fifo.path, 0o600) == 0 else {
            Self.log.error("cli probe listener: mkfifo failed", [
                "path": fifo.path,
                "errno": String(cString: strerror(errno))
            ])
            return
        }

        // Reader first (non-blocking open succeeds with no writer), then the
        // keepalive writer (succeeds because our own reader now exists).
        let fd = open(fifo.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            Self.log.error("cli probe listener: cannot open FIFO for reading", [
                "errno": String(cString: strerror(errno))
            ])
            unlink(fifo.path)
            return
        }
        let keepalive = open(fifo.path, O_WRONLY | O_NONBLOCK)
        guard keepalive >= 0 else {
            Self.log.error("cli probe listener: cannot open keepalive writer", [
                "errno": String(cString: strerror(errno))
            ])
            close(fd)
            unlink(fifo.path)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.drain(fd: fd)
        }
        source.resume()

        fifoURL = fifo
        readFD = fd
        keepaliveFD = keepalive
        readSource = source

        // The exit-criterion breadcrumb: the FIFO's absolute path, so a
        // verification run can compare it against `guesswho-cli probe`'s
        // container output (same path ⇒ same group ⇒ INV-4 holds at runtime).
        Self.log.notice("cli probe listener ready", [
            "group": groupID,
            "fifo": fifo.path
        ])
    }

    /// Tears the FIFO down. The file is removed so a probe against a stopped
    /// listener fails with ENOENT (clearly "not running") rather than
    /// half-connecting to an orphaned pipe.
    func stop() {
        guard isRunning else { return }
        readSource?.cancel()
        readSource = nil
        if readFD >= 0 { close(readFD) }
        if keepaliveFD >= 0 { close(keepaliveFD) }
        readFD = -1
        keepaliveFD = -1
        if let fifoURL {
            unlink(fifoURL.path)
        }
        fifoURL = nil
        pending.removeAll()
        Self.log.notice("cli probe listener stopped")
    }

    private func drain(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                continue
            }
            // 0 = EOF (suppressed by the keepalive writer, but harmless),
            // -1 + EAGAIN = drained. Either way, stop reading for now.
            break
        }
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            // THE "connected" line for Phase 0's client-spawn criterion.
            Self.log.notice("cli probe connected", ["line": line])
        }
    }
}
#endif
