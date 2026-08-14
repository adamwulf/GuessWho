import Foundation
import GuessWhoMCPWire
import MCP

/// The shared, non-binary response renderer. It reuses the wire's own
/// `WireResponse.asCallToolResult()` (Sources/GuessWhoMCPWire/WireResponse.swift)
/// so CLI output is byte-identical to the MCP agent surface: data payloads
/// become the same sorted-keys JSON, acks the same fixed strings, errors the
/// same plain messages — and the INV-3 / banned-vocabulary guarantees already
/// tested against that rendering apply to the CLI for free.
///
/// This retires the duplicate `CLICommandOutput.writeJSON` re-encode: the JSON
/// text `asCallToolResult` produces IS what we print (+ one trailing newline).
public enum CLIResponseRenderer {
    /// Render a response to the sink and return the exit code. A data/ack
    /// result goes to stdout (exit 0); an error result's plain message goes to
    /// stderr (exit 1) — the typed code name is never printed.
    public static func render(_ response: WireResponse, to sink: any CLIOutput) -> CLIExitCode {
        let result = response.asCallToolResult()
        let text = textContent(of: result)
        if result.isError == true {
            sink.writeError(text)
            return .appError
        }
        sink.writeLine(text)
        return .success
    }

    /// Concatenate the text blocks of a call-tool result. The wire renderer
    /// emits exactly one `.text` block per response, but joining is robust to
    /// more.
    static func textContent(of result: MCP.CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }
}
