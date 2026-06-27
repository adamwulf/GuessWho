import Logging

/// Ergonomic structured-logging sugar over swift-log's `Logger`.
///
/// swift-log's native metadata API requires wrapping every value in a
/// `Logger.MetadataValue` case:
/// ```swift
/// log.info("park wrote", metadata: ["bytes": .stringConvertible(count), "path": .string(path)])
/// ```
/// These overloads let callers pass a plain dictionary instead:
/// ```swift
/// log.info("park wrote", ["bytes": count, "path": url])
/// ```
/// Values are `CustomStringConvertible` (so `Int`, `String`, `URL`, `UUID`, …
/// all work directly and the compiler rejects nonsensical values), and each is
/// bridged to `.stringConvertible`, which `LogfmtLogHandler` already flattens
/// into the logfmt line. The trailing `file`/`function`/`line` are forwarded so
/// swift-log's source attribution is preserved.
extension Logger {

    /// `trace` with a plain `[String: CustomStringConvertible]` metadata bag.
    public func trace(
        _ message: @autoclosure () -> Logger.Message,
        _ metadata: [String: CustomStringConvertible],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(level: .trace, message(), metadata: Self.bridge(metadata), file: file, function: function, line: line)
    }

    /// `debug` with a plain `[String: CustomStringConvertible]` metadata bag.
    public func debug(
        _ message: @autoclosure () -> Logger.Message,
        _ metadata: [String: CustomStringConvertible],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(level: .debug, message(), metadata: Self.bridge(metadata), file: file, function: function, line: line)
    }

    /// `info` with a plain `[String: CustomStringConvertible]` metadata bag.
    public func info(
        _ message: @autoclosure () -> Logger.Message,
        _ metadata: [String: CustomStringConvertible],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(level: .info, message(), metadata: Self.bridge(metadata), file: file, function: function, line: line)
    }

    /// `notice` with a plain `[String: CustomStringConvertible]` metadata bag.
    public func notice(
        _ message: @autoclosure () -> Logger.Message,
        _ metadata: [String: CustomStringConvertible],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(level: .notice, message(), metadata: Self.bridge(metadata), file: file, function: function, line: line)
    }

    /// `warning` with a plain `[String: CustomStringConvertible]` metadata bag.
    public func warning(
        _ message: @autoclosure () -> Logger.Message,
        _ metadata: [String: CustomStringConvertible],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(level: .warning, message(), metadata: Self.bridge(metadata), file: file, function: function, line: line)
    }

    /// `error` with a plain `[String: CustomStringConvertible]` metadata bag.
    public func error(
        _ message: @autoclosure () -> Logger.Message,
        _ metadata: [String: CustomStringConvertible],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(level: .error, message(), metadata: Self.bridge(metadata), file: file, function: function, line: line)
    }

    /// `critical` with a plain `[String: CustomStringConvertible]` metadata bag.
    public func critical(
        _ message: @autoclosure () -> Logger.Message,
        _ metadata: [String: CustomStringConvertible],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(level: .critical, message(), metadata: Self.bridge(metadata), file: file, function: function, line: line)
    }

    /// Bridge a `[String: CustomStringConvertible]` bag into `Logger.Metadata`,
    /// wrapping each value as `.stringConvertible` so the value's own
    /// `description` is used (and `LogfmtLogHandler` flattens it consistently).
    private static func bridge(_ metadata: [String: CustomStringConvertible]) -> Logger.Metadata {
        var out = Logger.Metadata()
        out.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            out[key] = .stringConvertible(AnyMetadataValue(value))
        }
        return out
    }
}

/// Wraps a `CustomStringConvertible` so it satisfies swift-log's
/// `.stringConvertible` case, which requires
/// `CustomStringConvertible & Sendable`. The wrapped value's `description` is
/// captured eagerly so the wrapper itself is trivially `Sendable` regardless of
/// the source value's own conformance.
private struct AnyMetadataValue: CustomStringConvertible, Sendable {
    let description: String
    init(_ value: CustomStringConvertible) {
        self.description = value.description
    }
}
