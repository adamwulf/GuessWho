import Foundation
import GuessWhoMCPWire

/// The `contacts set-photo` input side, as a pure helper so `swift test` can
/// exercise the bounds/read logic over in-memory handles. Reads from a file
/// path or stdin (path `nil` or `"-"`), bounded so a runaway stream can't
/// exhaust memory: it stops one byte past the wire cap, and the caller rejects
/// anything over the cap. Moved verbatim in behavior from the retired
/// `CLIPhotoInput` (App/guesswho-cli/ContactsCommand.swift).
public enum CLIPhotoInput {
    /// Read image bytes from `path` (a file) or, when `path` is `nil` or
    /// `"-"`, from `stdin`. Throws `CLIUsageError` on an unreadable source.
    public static func read(path: String?) throws -> Data {
        if let path, path != "-" {
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
