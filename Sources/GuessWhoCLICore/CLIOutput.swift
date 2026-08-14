import Foundation

/// Where a CLI command's output goes. Three sinks so the funnel can keep the
/// UNIX contract "stdout is data, stderr is everything else" (§4): data
/// payloads and ack lines to stdout, every diagnostic/error to stderr.
///
/// The live conformance writes to the process's stdout/stderr; tests install
/// a capturing sink and assert on the buffers, which is what lets the render
/// path run under `swift test` with no live app.
public protocol CLIOutput: Sendable {
    /// Raw bytes to stdout with no trailing newline — the photo byte path.
    func writeData(_ data: Data)
    /// One line to stdout, terminated with a single newline — JSON payloads
    /// (from `WireResponse.asCallToolResult`) and ack messages.
    func writeLine(_ line: String)
    /// One line to stderr, terminated with a single newline — errors,
    /// diagnostics, and progress.
    func writeError(_ message: String)
}

/// The live sink: stdout bytes + stderr text. Best-effort writes — a broken
/// output stream (EPIPE) can't be reported through a stream that is itself
/// gone, and the process takes SIGPIPE for the truly fatal case.
public final class StandardCLIOutput: CLIOutput, @unchecked Sendable {
    public init() {}

    public func writeData(_ data: Data) {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    public func writeLine(_ line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    public func writeError(_ message: String) {
        var data = Data(message.utf8)
        data.append(0x0A)
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
