import Foundation

// A closure the host app installs on a sidecar store to decide what should
// happen when a coordinated read/write/delete doesn't finish within the
// store's per-attempt budget (1 second, internal to the store). This is
// modeled on SQLite's busy handler: the store calls the closure when it
// would otherwise be stuck waiting, and the closure decides whether to
// keep trying, back off, or give up.
//
// - `key` is the sidecar the slow operation is targeting.
// - `attempt` is 0-indexed (0 = the operation has already failed once).
// - `elapsed` is the total time since the first coordinator call started.
//
// Default handler: retry up to 3 times with exponential backoff starting at
// 250ms, then fail. App devs who want "best effort, eventually fail" do
// nothing; app devs who want "block forever" install a handler that returns
// `.retry` forever; app devs who want their own backoff write a custom
// closure. No cloudd vocabulary is exposed by any of this.
public typealias SidecarBusyHandler = (
    _ key: SidecarKey,
    _ attempt: Int,
    _ elapsed: TimeInterval
) -> SidecarBusyDecision

public enum SidecarBusyDecision: Equatable {
    // Try the coordinated operation again immediately.
    case retry

    // Sleep for the given interval, then try again. Negative or zero
    // intervals are treated as `.retry`.
    case retryAfter(TimeInterval)

    // Give up; the store throws `SidecarStoreError.timedOut(key)`.
    case fail
}

// The default handler used by FileSystemSidecarStore when no handler is
// installed: 3 retries, exponential backoff starting at 250ms (250, 500,
// 1000), then fail.
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
