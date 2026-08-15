import ArgumentParser
import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// A `CLIOutput` that captures what a command would print, so the render path
/// runs with no live app. stdout accumulates as raw bytes (photo bytes and
/// newline-terminated lines both land here); stderr accumulates as text.
final class CapturingCLIOutput: CLIOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = ""

    func writeData(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        _stdout.append(data)
    }

    func writeLine(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _stdout.append(Data(line.utf8))
        _stdout.append(0x0A)
    }

    func writeError(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        _stderr += message + "\n"
    }

    var stdoutData: Data { lock.lock(); defer { lock.unlock() }; return _stdout }
    var stdoutString: String { String(decoding: stdoutData, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return _stderr }
}

/// Returns a canned response, ignoring the request.
struct StubCLITransport: CLITransport {
    let response: WireResponse
    func send(_ request: WireRequest, timeout: TimeInterval) async throws -> WireResponse {
        response
    }
}

/// Always throws — for the transport-error mapping tests.
struct ThrowingCLITransport: CLITransport {
    let error: Error
    func send(_ request: WireRequest, timeout: TimeInterval) async throws -> WireResponse {
        throw error
    }
}

/// Records the request it was handed, then returns a canned response. Used
/// only from serial XCTest methods within a single `run()` call, so the
/// recording needs no lock.
final class RecordingCLITransport: CLITransport, @unchecked Sendable {
    let response: WireResponse
    private(set) var recorded: WireRequest?
    private(set) var timeout: TimeInterval?

    init(response: WireResponse) { self.response = response }

    func send(_ request: WireRequest, timeout: TimeInterval) async throws -> WireResponse {
        recorded = request
        self.timeout = timeout
        return response
    }
}

/// Base class for tests that install a fake `CLIRuntime`. `tearDown` restores
/// the unconfigured runtime so no fake leaks into the next test — belt-and-
/// suspenders on top of every command test installing its own first. Any test
/// that does NOT install a runtime therefore sees the throwing default, not a
/// prior test's fake.
class CLICommandTestCase: XCTestCase {
    override func tearDown() {
        CLIRuntime.current = .unconfigured()
        super.tearDown()
    }
}

extension XCTestCase {
    /// Install a fake runtime for the duration of a test. Every test that runs
    /// a command sets this first; XCTest runs methods serially, so the shared
    /// static is safe.
    @discardableResult
    func installRuntime(
        transport: any CLITransport,
        output: CapturingCLIOutput = CapturingCLIOutput(),
        container: URL = URL(fileURLWithPath: "/tmp/guesswho-cli-tests"),
        groupID: String = "group.test.guesswho"
    ) -> CapturingCLIOutput {
        CLIRuntime.current = CLIRuntime(
            containerURL: { container },
            groupID: { groupID },
            makeTransport: { _ in transport },
            output: output)
        return output
    }

    /// Run `body` and return the `ExitCode` it throws, or `nil` if it returned
    /// normally (success). Fails the test on any other thrown error.
    func exitCode(
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async -> Int32? {
        do {
            try await body()
            return nil
        } catch let code as ExitCode {
            return code.rawValue
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }
}

/// The JSON text `WireResponse.asCallToolResult()` emits for an encodable
/// payload — the expected stdout body (before the trailing newline) for a
/// data response.
func expectedJSONText<Payload: Encodable>(_ payload: Payload) throws -> String {
    let data = try WireResponse.agentJSONEncoder.encode(payload)
    return String(decoding: data, as: UTF8.self)
}

/// Canonical (sorted-keys) encoding of a request, so two semantically equal
/// requests compare byte-for-byte regardless of dictionary key ordering — the
/// framing tests' technique (WireFramingTests) made deterministic.
func canonicalEncoding(_ request: WireRequest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(request)
}
