import Foundation
import MCP

/// The `--json` structured-input side, shared by `favorites reorder` and
/// `guides create` and reused by later phases. The JSON comes from exactly one
/// of an inline `--json <text>`, `--json -` (stdin), or a `--json-file <path>`
/// companion, and is decoded to an MCP `Value` (which is `Codable`) that goes
/// STRAIGHT into the argument bag under the schema key. Because the decoded
/// value funnels through the same `WireRequest.create` validation the MCP path
/// uses, there is no second validator here — malformed JSON is the only failure
/// this layer owns, and it surfaces as a usage error, never a crash.
///
/// The stdin/file forms compose with `jq` and heredocs and carry no
/// shell-quoting hazard. Kept pure so `swift test` exercises it over in-memory
/// handles.
public enum CLIJSONInput {
    /// The largest JSON payload the CLI reads from a stream, in bytes. Guards a
    /// runaway stream; the wire builder bounds the meaningful sizes.
    public static let maxJSONBytes = 1_048_576 // 1 MiB

    /// Resolve and decode the `--json` payload, or return `nil` when neither
    /// `--json` nor `--json-file` was supplied (the payload is optional on some
    /// commands — a required one becomes a missing-argument error at the wire
    /// builder once its key is absent from the bag).
    ///
    /// * `inline` non-nil and not `"-"`: parse the literal text.
    /// * `inline == "-"`: read and parse stdin.
    /// * `file` non-nil: read and parse that file.
    ///
    /// Supplying both sources is a usage error; malformed JSON is a usage error.
    public static func read(inline: String?, file: String?) throws -> Value? {
        let text: String
        switch (inline, file) {
        case (.some, .some):
            throw CLIUsageError("Give the JSON with either --json or --json-file, not both.")
        case (nil, nil):
            return nil
        case (.some(let inline), nil):
            text = inline == "-"
                ? try readBounded(from: .standardInput, source: "stdin")
                : inline
        case (nil, .some(let path)):
            let expandedPath = (path as NSString).expandingTildeInPath
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: expandedPath))
            } catch {
                throw CLIUsageError("Could not open \(expandedPath): \(error.localizedDescription)")
            }
            defer { try? handle.close() }
            text = try readBounded(from: handle, source: expandedPath)
        }
        return try decode(text)
    }

    /// Place the decoded `--json` payload into `bag` under `key`, refusing to
    /// overwrite a value a per-field flag already set — a key supplied BOTH by a
    /// flag and `--json` is a usage error, never a silent merge. Phase 3's
    /// payloads are whole arrays under one key; a later phase merging a JSON
    /// object checks each of its keys the same way.
    public static func assign(_ value: Value, toKey key: String, in bag: inout [String: Value]) throws {
        guard bag[key] == nil else {
            throw CLIUsageError("The \(key) value was given both by a flag and by --json. Use only one.")
        }
        bag[key] = value
    }

    /// Decode JSON text to a `Value`, mapping any decode failure to a usage
    /// error (never a trap). The error text does not echo the payload.
    static func decode(_ text: String) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        } catch {
            throw CLIUsageError("The --json value is not valid JSON: \(error.localizedDescription)")
        }
    }

    /// Read up to `maxJSONBytes + 1` bytes in 64 KiB chunks — one byte past the
    /// cap so an over-cap payload is rejected rather than truncated — and decode
    /// as UTF-8.
    static func readBounded(from handle: FileHandle, source: String) throws -> String {
        let maximum = maxJSONBytes
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
            throw CLIUsageError("Could not read the JSON from \(source): \(error.localizedDescription)")
        }
        guard data.count <= maximum else {
            throw CLIUsageError("The --json value is larger than \(maximum) bytes.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
