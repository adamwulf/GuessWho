import Foundation

// Closure invoked when a sidecar read/write/delete is taking longer than
// the store's per-attempt budget. Modeled on SQLite's busy handler: the
// store calls this closure when it would otherwise be stuck, and the
// closure decides whether to keep waiting, back off, or give up.
//
// - `key`: the sidecar the slow operation is targeting.
// - `attempt`: 0-indexed (0 = the first wait window already timed out).
// - `elapsed`: total time since the operation started.
//
// Default: retry up to 3 times with exponential backoff from 250ms, then
// fail. Install `{ _, _, _ in .retry }` to block forever; write a custom
// closure for app-specific backoff.
public typealias SidecarBusyHandler = (
    _ key: SidecarKey,
    _ attempt: Int,
    _ elapsed: TimeInterval
) -> SidecarBusyDecision

public enum SidecarBusyDecision: Equatable {
    // Keep waiting for the in-flight operation.
    case retry

    // Sleep for the given interval, then keep waiting. Negative or zero
    // intervals are treated as `.retry`.
    case retryAfter(TimeInterval)

    // Give up; the store throws `SidecarStoreError.timedOut(key)`.
    case fail
}

// The default handler: 3 retries with exponential backoff (250ms, 500ms,
// 1000ms), then fail.
//
// Exposed publicly so a custom handler can fall back to the default after
// applying its own rules (e.g. "log first, then default").
public func defaultSidecarBusyHandler(
    key: SidecarKey,
    attempt: Int,
    elapsed: TimeInterval
) -> SidecarBusyDecision {
    if attempt >= 3 { return .fail }
    let delay = 0.25 * pow(2.0, Double(attempt))
    return .retryAfter(delay)
}
