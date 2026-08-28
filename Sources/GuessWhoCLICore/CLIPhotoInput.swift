import Foundation
import GuessWhoMCPWire

/// The `contacts set-photo` input side, as a pure helper so `swift test` can
/// exercise the bounds/read logic over in-memory handles. Reads image bytes
/// from stdin, bounded so a runaway stream can't exhaust memory: it stops one
/// byte past the wire cap, and the caller rejects anything over the cap.
///
/// stdin is the ONLY source. A `--input <path>` option was removed: the
/// sandboxed CLI helper cannot open files outside its container, so a path
/// failed for ordinary locations (e.g. /private/tmp) with a misleading
/// "permission to save the file" error. Callers pass a file with shell
/// redirection or a pipe (`... set-photo <id> < file`, `cat file | ...`),
/// which the shell opens and hands to the helper as an inherited descriptor —
/// the sandbox does not re-check it.
public enum CLIPhotoInput {
    /// Read image bytes from `stdin`, bounded. Throws `CLIUsageError` on a
    /// read error.
    public static func read() throws -> Data {
        return try readBounded(from: .standardInput, source: "stdin")
    }

    /// Read up to `maxContactPhotoBytes + 1` bytes in 64 KiB chunks — one byte
    /// past the cap so the caller can distinguish "at the cap" from "over it".
    public static func readBounded(from handle: FileHandle, source: String) throws -> Data {
        let maximum = WireEnvironment.maxContactPhotoBytes
        var data = Data()
        do {
            while data.count <= maximum {
                let remaining = maximum + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            throw CLIUsageError("Could not read image data from \(source): \(error.localizedDescription)")
        }
        return data
    }
}
