import Foundation

/// The `--body` text-input side, shared by the note write commands and reused by
/// later phases. A body comes from exactly one of three sources — an inline
/// `--body <text>`, `--body -` (stdin), or a `--body-file <path>` companion —
/// mirroring the photo commands' `<file | ->` convention (`CLIPhotoInput`).
///
/// Bounded like the photo read so a runaway stdin/file stream can't exhaust
/// memory: it reads one byte past the cap and rejects anything over the cap as a
/// usage error rather than silently truncating. A note body is small, so the cap
/// is a generous safety bound, not a product limit — the app applies its own
/// rules server-side. Kept pure so `swift test` exercises the read logic over
/// in-memory handles.
public enum CLITextInput {
    /// The largest body the CLI reads from a stream, in bytes. Generous for a
    /// text note; the bound guards a runaway stream, not the product rule.
    public static let maxBodyBytes = 1_048_576 // 1 MiB

    /// Resolve the body from the mutually-exclusive `--body` / `--body-file`
    /// flags. Exactly one source must be present:
    /// * `inline` non-nil and not `"-"`: the literal text.
    /// * `inline == "-"`: read stdin.
    /// * `file` non-nil: read that file.
    ///
    /// Supplying both, or neither, is a usage error. An empty body is NOT
    /// rejected here — the wire builder's non-empty check is the single source
    /// of truth for that.
    public static func read(inline: String?, file: String?) throws -> String {
        switch (inline, file) {
        case (.some, .some):
            throw CLIUsageError("Give the note body with either --body or --body-file, not both.")
        case (nil, nil):
            throw CLIUsageError("The note body is required. Pass --body <text>, --body - to read stdin, or --body-file <path>.")
        case (.some(let inline), nil):
            if inline == "-" {
                return try readBounded(from: .standardInput, source: "stdin")
            }
            return inline
        case (nil, .some(let path)):
            let expandedPath = (path as NSString).expandingTildeInPath
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: expandedPath))
            } catch {
                throw CLIUsageError("Could not open \(expandedPath): \(error.localizedDescription)")
            }
            defer { try? handle.close() }
            return try readBounded(from: handle, source: expandedPath)
        }
    }

    /// Read up to `maxBodyBytes + 1` bytes in 64 KiB chunks — one byte past the
    /// cap so an over-cap body is rejected rather than truncated — and decode as
    /// UTF-8.
    public static func readBounded(from handle: FileHandle, source: String) throws -> String {
        let maximum = maxBodyBytes
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
            throw CLIUsageError("Could not read the note body from \(source): \(error.localizedDescription)")
        }
        guard data.count <= maximum else {
            throw CLIUsageError("The note body is larger than \(maximum) bytes.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
