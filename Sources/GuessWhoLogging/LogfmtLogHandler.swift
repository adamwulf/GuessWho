import Foundation
import Logging
import Logfmt

/// A swift-log `LogHandler` that formats each record as a single clean
/// **logfmt** line and appends it to a `LogFileWriter`.
///
/// Line shape (stable leading key order, then logfmt-sorted trailing pairs):
/// ```
/// ts=2026-06-27T12:34:56.789Z level=info label=app.linkedin-handoff msg="…" key=val …
/// ```
/// The fixed leading fields (`ts`, `level`, `label`) are emitted by hand so
/// their order is stable. Everything after them (`msg` + flattened metadata)
/// comes from a single `String.logfmt(_:)` call over one dictionary — which is
/// a whole-object formatter that emits `key=value` pairs, sorts keys, and
/// quotes/escapes values (B2).
///
/// **One record = one line (B3):** `String.logfmt` quotes and backslash-escapes
/// but has no newline handling, so we strip `\r`/`\n` (and other control
/// characters) out of the message and every metadata value ourselves before
/// formatting. `error.localizedDescription` routinely contains newlines.
///
/// **Note (N5):** log bodies are developer-facing and intentionally exempt from
/// the no-internal-vocabulary product rule — labels like `app.linkedin-handoff`
/// and message text like `[GuessWho] …` are expected here. Do not "fix" them.
struct LogfmtLogHandler: LogHandler {

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    let label: String
    private let writer: LogFileWriter

    init(label: String, writer: LogFileWriter) {
        self.label = label
        self.writer = writer
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    // swift-log 1.14 prefers `log(event:)` over the older
    // `log(level:message:metadata:source:file:function:line:)` (which it
    // deprecated). Implementing `log(event:)` is the supported path and also
    // gives us the event's optional `error`.
    func log(event: LogEvent) {
        // Merge per-log metadata over the handler's base metadata.
        var merged = mergedMetadata(event.metadata)
        // Fold an attached error (if any) into the metadata bag so it lands in
        // the line. Its localizedDescription routinely contains newlines, which
        // `format` sanitizes.
        if let error = event.error {
            merged["error"] = .string(String(describing: error))
        }
        let line = Self.format(
            timestamp: Date(),
            level: event.level,
            label: label,
            message: event.message.description,
            metadata: merged
        )
        writer.write(line)
    }

    private func mergedMetadata(_ explicit: Logger.Metadata?) -> Logger.Metadata {
        guard let explicit, !explicit.isEmpty else { return metadata }
        guard !metadata.isEmpty else { return explicit }
        var out = metadata
        for (k, v) in explicit { out[k] = v }
        return out
    }

    // MARK: - Formatting (static so tests can exercise it without a writer)

    /// Build the full logfmt line for one record. Pure — no I/O.
    static func format(
        timestamp: Date,
        level: Logger.Level,
        label: String,
        message: String,
        metadata: Logger.Metadata
    ) -> String {
        // Leading fields by hand so the order (ts, level, label) is stable and
        // independent of logfmt's key sorting.
        var line = "ts=\(Self.timestampString(timestamp))"
        line += " level=\(level.rawValue)"
        line += " label=\(logfmtScalar(label))"

        // Trailing pairs: one dictionary handed to String.logfmt. It emits
        // `key=value`, sorts keys, and quotes/escapes values for us — we only
        // sanitize newlines first (B3).
        var bag: [String: Any] = ["msg": sanitize(message)]
        for (key, value) in metadata {
            bag[key] = sanitize(flatten(value))
        }
        let pairs = String.logfmt(bag)
        if !pairs.isEmpty {
            line += " \(pairs)"
        }
        return line
    }

    /// ISO-8601 with fractional seconds in UTC. The formatter is created per
    /// call's-worth cheaply via a cached static; `ISO8601DateFormatter` is not
    /// `Sendable`-safe to mutate, so we keep one per thread is overkill — a
    /// single cached instance read-only after configuration is fine here since
    /// `string(from:)` is thread-safe on a configured formatter.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func timestampString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Quote/escape a single scalar the same way Logfmt would for a bare value
    /// (used for the hand-emitted leading `label` field). Wrap in quotes if it
    /// contains a space or quote; backslash-escape backslashes and quotes.
    private static func logfmtScalar(_ value: String) -> String {
        let clean = sanitizeString(value)
        guard clean.contains(" ") || clean.contains("\"") || clean.isEmpty else {
            return clean
        }
        var escaped = ""
        for ch in clean {
            if ch == "\\" || ch == "\"" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    /// Flatten a swift-log metadata value to a string. Nested dictionaries and
    /// arrays are handed back to `String.logfmt` as native collections so it can
    /// dot-flatten them; scalars become their string form.
    private static func flatten(_ value: Logger.Metadata.Value) -> Any {
        switch value {
        case .string(let s): return s
        case .stringConvertible(let c): return c.description
        case .dictionary(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = flatten(v) }
            return out
        case .array(let arr):
            return arr.map { flatten($0) }
        }
    }

    /// Collapse `\r`/`\n` (and other control characters) so one record stays on
    /// one line. We replace CR/LF with a single space; other control characters
    /// are dropped. Applied recursively to collection values.
    private static func sanitize(_ value: Any) -> Any {
        if let s = value as? String {
            return sanitizeString(s)
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitize(v) }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { sanitize($0) }
        }
        return value
    }

    private static func sanitizeString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                out.append(" ")
            } else if CharacterSet.controlCharacters.contains(scalar) {
                // Drop other control characters (e.g. tabs/escapes that could
                // also break the single-line format).
                continue
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
