# MCP transport — write-source CPU spin fix

**Author:** `mcp-cpu-spin` (guesswho repo) · **Status:** DRAFT — for review by one `codex` and one `researcher` agent · **Date:** 2026-08-13

---

## Summary

The `GuessWho` app and the `guesswho-cli` helper both use near two full CPU
cores each (187% and 181% in Activity Monitor) while they are idle. The cause
is a busy-loop in the MCP FIFO transport. A `DispatchSourceWrite` in
`ChunkedWritePipe` stays armed all the time. A write source fires while the
file descriptor has space to write. An idle FIFO always has space. So the
event handler runs again and again and burns a core.

This plan fixes the spin. It arms the write source only while a writer waits
for space, and it keeps the source suspended at all other times.

## Evidence

Two `sample` captures show the same hot stack in both processes:

```
DispatchQueue_…: com.milestonemade.guesswho.mcp.pipe-write  (serial)
  _dispatch_source_invoke → _dispatch_source_latch_and_call
    → _dispatch_client_callout → PipeSignal.signal()
```

- App sample (pid 60030): two `pipe-write` queues (`DispatchQueue_4277`,
  `DispatchQueue_4310`) run hot inside `GuessWhoSync`. Two more worker
  threads churn in `_dispatch_workloop_worker_thread` /
  `_dispatch_event_loop_merge`.
- CLI sample (pid 60698): two `pipe-write` queues (`DispatchQueue_40`,
  `DispatchQueue_43`) run hot in `PipeSignal.signal()`.

The two processes do NOT drive each other. Each process runs the same
transport code, and each spins on its own always-armed write source. Two open
write pipes per process give about two busy cores per process. That matches
the CPU numbers.

## Root cause

`Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift`, in `open()`:

```swift
// ChunkedWritePipe.swift:112-124
let writeSource = DispatchSource.makeWriteSource(fileDescriptor: opened, queue: queue)
...
writeSource.resume()
// The source fires only on future writability EDGES; the pipe is
// almost certainly writable right now, so pre-arm one pass.
signal.signal()
```

The comment is wrong. `DISPATCH_SOURCE_TYPE_WRITE` is **level-triggered**, not
edge-triggered. It does not fire one time per rising edge. It fires the event
handler again and again while the file descriptor is writable. The code
resumes the source one time at `open()` and never suspends it. When the pipe
is open and idle, with no message to send, the handler calls
`PipeSignal.signal()` in a tight loop.

### Why the read source does not have this problem

`CappedLineReadPipe` (`CappedLineReadPipe.swift:133-142`) also resumes its
source for the full lifetime. But a read source fires only when data is
available to read. An idle FIFO has no data, so the read source stays quiet.
It is safe to leave the read source armed. **Do not change the read source.**
It must stay armed so reads are always driven by readability events (a parked
`read(2)` can wedge the FIFO — see the `docs`/test note on the 4 KB write
hazard).

## The fix

Arm the write source only while a writer is blocked on `EAGAIN`. Keep it
suspended the rest of the time.

A `DispatchSource` is created in the **suspended** state. So the fix is to NOT
resume it at `open()`, and to add a small armed/idle state machine around the
one place that waits for writability.

### Edit 1 — `open()`: create suspended, do not pre-arm

- Remove `writeSource.resume()`.
- Remove the pre-arm `signal.signal()` at the end of `open()`.
- Keep the event handler (`signal.signal()`) and the cancel handler (close fd
  + `signal.signal()`) as they are.

### Edit 2 — add armed state + helpers

Add one stored flag and two actor-isolated helpers. The flag tracks whether
the source is resumed (armed) or suspended (idle). It keeps the
suspend/resume count balanced.

```swift
private var isSourceArmed = false

private func armSource() {
    guard let source, !isSourceArmed else { return }
    isSourceArmed = true
    source.resume()
}

private func disarmSource() {
    guard let source, isSourceArmed else { return }
    isSourceArmed = false
    source.suspend()
}
```

### Edit 3 — `performWrite()`: arm around the wait

In the `EAGAIN` / `EWOULDBLOCK` branch:

```swift
case EAGAIN, EWOULDBLOCK:
    armSource()
    await writableSignal.wait()
    disarmSource()
```

The normal path (the pipe has space) never touches the source. So the source
stays suspended for the whole idle time.

### Edit 4 — `close()` and `deinit`: resume before cancel

This is the subtle, load-bearing part of the fix, and the main thing reviewers
must check.

After this fix the resting state of the source is **suspended**. GCD has two
hard rules for a suspended source:

1. `cancel()` on a suspended source does NOT run the cancel handler until the
   source is resumed. The cancel handler is what closes the file descriptor.
   A suspended-then-cancelled source would leak the fd.
2. Releasing the last reference to a suspended source crashes the process:
   `BUG IN CLIENT OF LIBDISPATCH: Release of a suspended object`.

Today `close()` and `deinit` call `source.cancel()` directly. That is safe
today only because the source is always resumed today. After the fix, both
paths must resume the source first if it is suspended:

`close()`:

```swift
if let source {
    if !isSourceArmed { source.resume(); isSourceArmed = true }
    source.cancel()          // cancel handler closes the fd + signals waiter
    self.source = nil
    isSourceArmed = false
}
```

`deinit` (nonisolated, but has exclusive access, so it can read the stored
properties directly):

```swift
if let source {
    if !isSourceArmed { source.resume() }
    source.cancel()
} else if fd >= 0 {
    Darwin.close(fd)
}
```

If a caller follows the documented `cancel → wake → await → close` lifecycle,
`close()` runs first and sets `source = nil`, so the `deinit` branch is a
fallback. The `deinit` guard still matters for any path that deallocates
without a prior `close()`.

## Correctness notes (for reviewers)

- **Single writer at a time.** Concurrent `write()` calls serialize through
  the `lastWrite` task chain (`ChunkedWritePipe.swift:133-139`). So only one
  `performWrite` touches the source at a time. `isSourceArmed` stays 0 or 1.
- **No lost wakeup.** The source is level-triggered. If the pipe becomes
  writable in the small window between the `EAGAIN` and `armSource()`, the
  handler fires as soon as the source resumes, because the fd is already
  writable. `PipeSignal` also holds a `pendingSignal` flag, so a signal that
  lands before the waiter parks is not lost.
- **Bounded stale-signal cost.** Between the wake and `disarmSource()` the
  source can fire a few more times (the pipe is writable) and set
  `pendingSignal = true`. On the next `EAGAIN` cycle `wait()` returns at once
  and consumes the flag, which costs at most one extra `write(2)` that returns
  `EAGAIN`. It is a bounded, one-shot cost, not a loop.
- **close() during a parked write.** `close()` resumes-then-cancels while the
  writer is parked in `wait()`. The cancel handler signals the waiter. The
  waiter returns, calls `disarmSource()` (now a no-op because `source == nil`),
  loops, sees `fd == -1`, and throws `pipeNotOpened`. No crash, no leak.
- **Secondary hot threads.** The `_dispatch_workloop_worker_thread` /
  `_dispatch_event_loop_merge` churn in the samples is the kevent re-arm cost
  of the constantly-firing source. It should go quiet once the write source is
  gated. It is not a separate bug.
- **Out of scope.** The CLI sample shows `StdioTransport.readLoop()` in
  `Task._sleep` with about 4 samples. That is noise, not the spin. Do not
  change it in this fix.

## Regression test

Add a test to `Tests/GuessWhoMCPTransportTests/` that fails on the old code
and passes on the fixed code. Two options; the deterministic one is preferred.

**Option A — deterministic fire counter (preferred).** Add an internal,
test-only counter that the write source's event handler increments. Use
`@testable import GuessWhoMCPTransport`. Open a `ChunkedWritePipe` against a
real FIFO whose read end a helper fd holds open, keep it idle for a short
interval, and assert the counter stays at or below a small bound (for example
`<= 2`). On the old code the counter climbs into the thousands.

**Option B — CPU-time delta (backup).** Read `getrusage(RUSAGE_SELF)`
`ru_utime + ru_stime` before and after a 500 ms idle window with the write
pipe open. Assert the delta stays well under the window (for example
`< 100 ms`). On the old code the delta is about a full 500 ms of CPU. Use a
wide threshold so the test is not timing-flaky.

Test setup notes:
- `ChunkedWritePipe.open()` opens `O_WRONLY | O_NONBLOCK` and fails with
  `ENXIO` when no reader holds the pipe. The test must open a reader fd first
  (`O_RDONLY | O_NONBLOCK`) and hold it for the idle window.
- Follow the temp-dir container pattern in
  `PipeTransportTests.swift:28-45`.

## Files touched

- `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift` — the fix (Edits 1–4).
- `Tests/GuessWhoMCPTransportTests/PipeTransportTests.swift` (or a new file in
  the same target) — the regression test.
- No change to `CappedLineReadPipe.swift`. State explicitly in the PR why the
  read source is left armed, so a later change does not "fix" it and
  reintroduce the parked-read FIFO wedge.

## Verification

1. `swift build` — compiles the transport package.
2. `swift test --filter GuessWhoMCPTransport` — the new regression test plus
   the existing transport suite pass.
3. Manual check: run the app + `guesswho-cli`, open a connection, leave it
   idle, and confirm in Activity Monitor that both processes drop to near 0%
   CPU when idle.
4. Confirm normal traffic still round-trips: the existing
   `testConcurrentLargeRequestsFromTwoHelpersArriveIntact` and the framing /
   churn / host-restart tests stay green (they exercise the `EAGAIN` wait
   path under real load).

## Risks

- **Suspend/resume imbalance.** The single biggest risk. If any path resumes
  or suspends without matching the other, the count drifts. A suspended source
  that is released crashes the process. The `isSourceArmed` flag and the
  guards in the helpers keep the count balanced; the `close()` / `deinit`
  resume-before-cancel keeps release safe. Reviewers should trace every path.
- **Behavior under real load.** The fix must not slow large writes that
  legitimately hit `EAGAIN`. The arm/disarm is one resume + one suspend per
  block, which is cheap. The concurrent-large-request test covers this.
