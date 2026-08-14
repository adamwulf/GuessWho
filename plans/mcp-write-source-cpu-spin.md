# MCP transport — write-source CPU spin fix

**Author:** `mcp-cpu-spin` (guesswho repo) · **Date:** 2026-08-13
**Status:** Revised after review cycle 1. Two reviewers: one `codex`
(engineering), one `researcher` (facts). The researcher CONFIRMED all five
factual claims against the SDK dispatch headers, the Darwin man pages,
the libdispatch source, and Apple's Concurrency Programming Guide. The codex
reviewer approved the direction but found one blocker — a close/reopen
generation race — plus test refinements. All findings are folded in below.
Reviews: [`review-codex-cpu-spin.md`](review-codex-cpu-spin.md),
[`review-researcher-cpu-spin.md`](review-researcher-cpu-spin.md).

---

## Summary

The `GuessWho` app and the `guesswho-cli` helper both use near two full CPU
cores each (187% and 181% in Activity Monitor) while they are idle. The cause
is a busy-loop in the MCP FIFO transport. A `DispatchSourceWrite` in
`ChunkedWritePipe` stays armed all the time. A write source fires while the
file descriptor has space to write. An idle FIFO always has space. So the
event handler runs again and again and burns a core.

This plan gates the write source. It arms the source only while a writer waits
for buffer space, and it keeps the source inactive at all other times. It also
makes the pipe one-shot, which closes a reopen race the reviewer found.

## Evidence

Two `sample` captures show the same hot stack in both processes:

```
DispatchQueue_…: com.milestonemade.guesswho.mcp.pipe-write  (serial)
  _dispatch_source_invoke → _dispatch_source_latch_and_call
    → _dispatch_client_callout → PipeSignal.signal()
```

- App sample (pid 60030): two `pipe-write` queues run hot inside
  `GuessWhoSync`. Two more worker threads churn in
  `_dispatch_workloop_worker_thread` / `_dispatch_event_loop_merge`.
- CLI sample (pid 60698): two `pipe-write` queues run hot in
  `PipeSignal.signal()`.

The two processes do NOT drive each other. Each process runs the same
transport code, and each spins on its own always-armed write source.

**How many hot pipes per process (corrected after review):** the count is not a
fixed two.

- The **CLI** structurally holds **two** write pipes — the announce pipe and
  the request pipe (`RelayConnection.swift:111, 146`). So the CLI spins about
  two cores by construction.
- The **app (host)** holds **one response writer per connected helper**
  (`MCPPipeHost.swift:165`). Two hot queues in the app sample mean two helpers
  were connected at capture time. With N helpers the app would spin about N
  cores. This is situational, not a fixed property. It makes the fix more
  important, not less.

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
edge-triggered. libdispatch registers the write source with
`EV_DISPATCH` but **without** `EV_CLEAR`, so after each delivery the invoke
path re-arms the kqueue note; a level filter on a still-writable fd then fires
again at once. The write low-water mark is 1 byte, so an idle FIFO with an
empty buffer is always writable. The code resumes the source one time at
`open()` and never suspends it. When the pipe is open and idle, with no message
to send, the handler calls `PipeSignal.signal()` in a tight loop. Apple's own
guide cancels a write source after the write "to prevent it from being called
again" — confirmation that an armed write source keeps firing.

Note one extra case the reviewer surfaced: when the read end disappears, the
write filter reports `EV_EOF` and **also** fires continuously. So an always-
armed write source spins both when the pipe is idle-but-healthy and when the
reader is gone. The gate below covers both cases. The manual idle round-trip
check (below) tells the two apart.

### Why the read source does not have this problem

`CappedLineReadPipe` (`CappedLineReadPipe.swift:133-142`) also keeps its source
armed for the whole lifetime. A read source fires only when data is available
to read. An idle FIFO holds no data, so the read source stays quiet. **Do not
change the read source.** It must stay armed so reads are always driven by
readability events (a parked `read(2)` can wedge the FIFO — the 4 KB write
hazard the transport exists to avoid).

Scope this claim correctly: the read source is safe **because of two
conditions the code already meets** — (1) each open pipe has exactly one
draining consumer, and (2) `CappedLineReadPipe` holds a keepalive `O_WRONLY`
fd on its own FIFO, so the kernel writer count never drops to zero and the read
source never enters the persistent `EV_EOF` state
(`CappedLineReadPipe.swift:122-130`). Do not claim the read source is
"unconditionally" non-spinning; claim it is quiet under this contract.

## The fix

Two parts. Part A gates the write source (stops the spin). Part B makes the
pipe one-shot (closes the reopen race).

### Part A — arm the write source only around a backpressure wait

A `DispatchSource` is created in the **inactive** state. So do not resume it at
`open()`. Arm it only while a writer is blocked on `EAGAIN`, and keep it
inactive/suspended the rest of the time.

#### Edit A1 — `open()`: create inactive, do not pre-arm

- Remove `writeSource.resume()`.
- Remove the pre-arm `signal.signal()` at the end of `open()`.
- Keep the event handler and the cancel handler.
- **Add a test probe to the event handler** (see the test section). The
  handler becomes `{ onSourceFire?(); signal.signal() }`, where `onSourceFire`
  is an optional `@Sendable () -> Void` injected at init (nil in production).
  The probe must fire ONLY from the write-source event handler, never from the
  cancel handler or from a manual `signal()`.

#### Edit A2 — armed state + helpers

```swift
private var isSourceArmed = false   // false ⇒ inactive/suspended, true ⇒ active

private func armSource() {
    guard let source, !isSourceArmed else { return }
    isSourceArmed = true
    source.resume()   // resume() on an inactive source acts as activate()
}

private func disarmSource() {
    guard let source, isSourceArmed else { return }
    isSourceArmed = false
    source.suspend()
}
```

#### Edit A3 — `performWrite()`: arm around the wait

```swift
case EAGAIN, EWOULDBLOCK:
    armSource()
    await writableSignal.wait()
    disarmSource()
```

The normal path (the pipe has space) never touches the source. So the source
stays inactive for the whole idle time, and the spin stops.

#### Edit A4 — `close()` and `deinit`: resume before cancel

This is the subtle, load-bearing part, and the main thing reviewers checked.

After this fix the resting state of the source is **inactive or suspended**.
GCD has two hard rules, both CONFIRMED by the researcher against the
`dispatch_object(3)` / `dispatch_source_create(3)` man pages and the
libdispatch source:

1. `cancel()` on a suspended/inactive source does NOT run the cancel handler
   until the source is resumed. The cancel handler is what closes the fd. A
   suspended-then-cancelled source that stays alive leaks the fd.
2. Releasing the last reference to a source that is not fully active crashes
   the process. The crash string depends on the sub-state:
   - never armed at all ⇒ **inactive** ⇒ `BUG IN CLIENT OF LIBDISPATCH:
     Release of an inactive object`.
   - armed then disarmed ⇒ **suspended** ⇒ `… Release of a suspended object`.

So both `close()` and `deinit` must resume the source first when it is not
armed. `resume()` on an inactive source acts as `activate()`, which covers the
never-armed path too.

`close()` (also make it one-shot — see Part B):

```swift
isClosed = true
if let source {
    if !isSourceArmed { source.resume(); isSourceArmed = true }
    source.cancel()          // cancel handler now runs: closes fd + signals waiter
    self.source = nil
    isSourceArmed = false
}
fd = -1
writableSignal.signal()      // wake any parked writer so it can observe close
lastWrite = nil
```

`deinit` (nonisolated, but has exclusive access, so it may read stored
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
fallback for the deallocate-without-close path.

### Part B — make the pipe one-shot (closes the reopen race)

**The reviewer's blocker.** The old `close()` proof was incomplete. `close()`
wakes a parked writer but does not await it, and `open()` accepts the same
instance again once `fd < 0`. That allows this interleaving:

1. Writer A gets `EAGAIN`, arms source A, and parks.
2. `close()` cancels source A, clears the stored source, sets `fd = -1`, and
   signals A.
3. Before A's continuation runs, `open()` installs a NEW source B on the same
   instance.
4. A new writer B arms source B and parks.
5. Writer A finally wakes and calls `disarmSource()`. It suspends the CURRENT
   source (B), then loops on the new `fd` and writes leftover bytes of the OLD
   payload into the NEW connection. Writer B is left waiting on a suspended
   source.

Actor isolation does not stop this reentrant sequence.

**Chosen contract: one-shot.** Every production caller already constructs a
fresh `ChunkedWritePipe` on reconnect and never reopens a closed one:

- `RelayConnection.connect()` builds new announce + request pipes each call
  (`RelayConnection.swift:111, 146`); `closePipes()` closes and nils them
  (`RelayConnection.swift:174-182`).
- `MCPPipeHost` builds a new response writer per session
  (`MCPPipeHost.swift:165`).

So a one-shot contract breaks no real caller and makes the race structurally
impossible — there is never a source B on the same instance.

#### Edit B1 — reject reopen after close

- Add `private var isClosed = false`.
- Add a `WritePipeError.pipeClosed` case.
- At the top of `open()`, before the existing `guard fd < 0 else { return }`:
  ```swift
  guard !isClosed else { throw WritePipeError.pipeClosed }
  ```
- `close()` sets `isClosed = true` (shown in Edit A4).

With reopen rejected, a stale parked writer A can only ever wake to
`source == nil` and `fd == -1`: `disarmSource()` is a no-op, and the write loop
throws `pipeNotOpened`. No stale bytes reach any new connection. This is a
"fail loudly" guard consistent with the repo's recent legacy-semantics commits.

## Correctness notes (for reviewers)

- **Single writer at a time.** Concurrent `write()` calls serialize through the
  `lastWrite` task chain (`ChunkedWritePipe.swift:133-139`). Only one
  `performWrite` touches the source at a time, so `isSourceArmed` stays 0 or 1.
  One-shot keeps this true across close: no second write chain ever shares the
  `PipeSignal`.
- **Inactive vs. suspended.** The initial source state is *inactive*, a
  distinct sub-state of suspended. Edit A4's resume-before-cancel covers both,
  because `resume()` activates an inactive source. Both bad-release crash
  strings ("inactive object" / "suspended object") are avoided.
- **No lost wakeup.** The source is level-triggered. If the pipe becomes
  writable in the small window between the `EAGAIN` and `armSource()`, the
  handler fires as soon as the source activates, because the fd is already
  writable. `PipeSignal` also holds one `pendingSignal` bit, so a signal that
  lands before the waiter parks is not lost.
- **Bounded stale-signal cost.** Between the wake and `disarmSource()` the
  source can fire a few more times and set `pendingSignal = true`. On the next
  `EAGAIN` cycle `wait()` returns at once and consumes the flag, costing at most
  one extra `write(2)` that returns `EAGAIN`. It is a bounded, one-shot cost,
  not a loop. This holds only with one waiter, which `lastWrite` + one-shot
  guarantee.
- **close() during a parked write.** `close()` resumes-then-cancels while the
  writer is parked in `wait()`. The cancel handler signals the waiter. The
  waiter returns, calls `disarmSource()` (a no-op because `source == nil`),
  loops, sees `fd == -1`, and throws `pipeNotOpened`. No crash, no leak.
- **Secondary hot threads.** The `_dispatch_workloop_worker_thread` /
  `_dispatch_event_loop_merge` churn in the samples is the per-invocation
  kqueue re-arm cost of the constantly-firing source. It should go quiet once
  the source is gated. It is not a separate bug.
- **Out of scope.** The CLI sample shows `StdioTransport.readLoop()` in
  `Task._sleep` with about 4 samples. A parked sleep burns no CPU; that is
  noise, not the spin. Do not change it in this fix.

## Regression tests

**Test-Driven Development — red first.** Write and land the headline idle-spin
test BEFORE the fix, and confirm it FAILS (red) against the current, buggy
`ChunkedWritePipe`. A test that cannot fail on the present spin is not a real
guard. Only after it is red do we apply Parts A and B and confirm it turns
green.

All tests go in `Tests/GuessWhoMCPTransportTests/` and use
`@testable import GuessWhoMCPTransport` (the current target uses a plain
import; the new file adds `@testable`). Follow the temp-dir container pattern in
`PipeTransportTests.swift:28-45`.

**Test harness facts (reviewer-confirmed):**
- `ChunkedWritePipe.open()` opens `O_WRONLY | O_NONBLOCK` and fails with
  `ENXIO` when no reader holds the pipe. Each test must open a raw
  `O_RDONLY | O_NONBLOCK` reader fd first and hold it for the window.
- The fire probe must be **race-free**. A plain actor property cannot be
  incremented synchronously from the dispatch event handler. Inject a
  `@Sendable () -> Void` at init that increments a **lock-guarded** counter
  owned by the test. Count only write-source event-handler entries. Do not
  reuse `PipeSignal.signal()` as the counter — the cancel handler and `close()`
  also call it.

### Test 1 — idle no-spin (the red/green headline)

Hold a reader open, open the writer, send nothing, wait a short settle
interval, and assert the injected fire counter is **exactly 0** before close
(not `<= 2`). On the old code the counter climbs without bound. A short settle
interval is still mildly time-based, but the old code's continuous firing gives
a wide margin.

Backup only, NOT the automated gate: a `getrusage(RUSAGE_SELF)` CPU-time delta
over a 500 ms idle window. It is vulnerable to parallel-test CPU, so keep it as
a manual diagnostic, not a committed assertion.

### Test 2 — the EAGAIN / backpressure path is really exercised

The existing `testConcurrentLargeRequestsFromTwoHelpersArriveIntact`
(`PipeTransportTests.swift:89-111`) uses actively draining readers, so it can
pass without any writer ever hitting `EAGAIN`. It does not prove the new
arm/wait/disarm path. Add:

- **Multi-EAGAIN, one payload.** Hold a reader open but do NOT drain, so the
  pipe fills and the writer parks on `EAGAIN`. Then drain in small increments
  to force more than one `EAGAIN`/wakeup cycle for a single payload. Assert the
  payload arrives byte-for-byte intact.
- **close() while parked.** Park a writer on `EAGAIN`, call `close()`, and
  assert the `write()` throws the expected error and the process does not crash.
- **Reopen contract (one-shot).** After `close()`, assert `open()` throws
  `WritePipeError.pipeClosed`.

### Test 3 — deinit without close (subprocess)

Edit A4 hardens `deinit` so a never-closed pipe does not release an
inactive/suspended source. The failure mode is a **libdispatch process abort**,
which XCTest cannot catch in-process. So this needs a subprocess:

- Add a tiny SwiftPM executable target that opens a `ChunkedWritePipe`, does no
  `EAGAIN`, drops the last reference WITHOUT calling `close()`, and exits 0.
- An XCTest spawns it with `Process` and asserts a clean exit (no abort).

An in-process companion test still helps: `open()` a writer with no `EAGAIN`
(source stays inactive), then `close()`; assert no crash and the fd is closed.
That exercises resume-before-cancel of an inactive source on the `close()` path.

## Files touched

- `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift` — Parts A + B; add the
  `onSourceFire` init probe and `isClosed`.
- `Sources/GuessWhoMCPTransport/WritePipeError.swift` (wherever the enum lives)
  — add `pipeClosed`.
- `Tests/GuessWhoMCPTransportTests/…` — a new `@testable` file for Tests 1–2
  plus the in-process deinit companion; and the subprocess-driver test.
- A tiny executable target for Test 3 (deinit-without-close). If adding a
  target is judged too heavy, fall back to code-review of the deinit path plus
  the in-process close-of-inactive test, and record that the pure
  deinit-without-close abort is not automatically gated.
- No change to `CappedLineReadPipe.swift`. State in the PR why the read source
  stays armed (single-consumer + keepalive contract), so a later change does
  not "fix" it and reintroduce the parked-read FIFO wedge.

## Verification

Follow the TDD order:

0. **Red:** land Test 1 first, run `swift test --filter GuessWhoMCPTransport`,
   and confirm Test 1 FAILS against the unmodified `ChunkedWritePipe`. Record
   the red output.
1. **Green:** apply Parts A + B, `swift build` to compile the transport package.
2. `swift test --filter GuessWhoMCPTransport` — Test 1 is now green, Tests 2–3
   pass, and the existing transport suite stays green.
3. Manual check: run the app + `guesswho-cli`, open a connection, leave it
   idle, and confirm in Activity Monitor that both processes drop to near 0%
   CPU. This idle round-trip check also confirms the connection is healthy, not
   in the `EV_EOF` dead-reader state.

## Rejected alternatives (weighed, not chosen)

- **Recreate a one-shot source per `EAGAIN`.** Avoids suspend/resume
  bookkeeping, but makes fd ownership and close-vs-handler ordering harder (a
  file-descriptor source must not let close race an outstanding handler).
- **Blocking `poll()` on a worker queue.** Trades the spin for a parked thread
  and still needs a reliable shutdown wake.
- **Move the pending-byte buffer and all writes onto the source's serial
  queue, arming readiness only while the buffer is nonempty.** A larger
  redesign than this fix warrants.

The persistent source with guarded arm/disarm plus a one-shot contract is the
smallest correct change.

## Risks

- **Suspend/resume imbalance.** The biggest risk. Over-resume terminates the
  process; under-resume trips the bad-release crash. The `isSourceArmed` guard
  keeps the count at 0 or 1, and resume-before-cancel in `close()`/`deinit`
  keeps release safe for both the inactive and suspended sub-states. Reviewers
  should trace every path.
- **Reopen race.** Closed by the one-shot contract (Part B). The reopen-throws
  test guards it.
- **deinit abort is process-fatal.** Not catchable in-process; hence the
  subprocess test.
- **Behavior under real load.** The fix must not slow large writes that
  legitimately hit `EAGAIN`. Arm/disarm is one resume + one suspend per block,
  which is cheap. Test 2 (multi-EAGAIN) plus the existing concurrent-large-
  request test cover this.
