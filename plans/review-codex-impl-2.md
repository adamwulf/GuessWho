# Focused re-review: MCP write-source test hardening (cycle 2)

**Verdict: REQUEST-CHANGES**

The new backpressure/disarm assertion and the deinit weak-reference assertion
close their intended regression holes, and the focused transport suite passes.
However, cycle 1's deadline-bounded-completion P1 is not resolved: the throwing
task-group helper cannot leave its scope while its operation child remains
parked on the unstructured writer task, so the timeout cleanup is unreachable
in exactly the lost-wake case it is meant to bound.

## Findings

1. **[P1] `withDeadline` still permits both writer waits to hang forever
   (`WriteSourceLifecycleTests.swift:91-103, 193-200, 244-250`).**

   If the timer child throws `TimeoutError`, `try await group.next()` throws
   before the explicit `group.cancelAll()` at line 100 runs. Swift then cancels
   the group's remaining child as part of leaving the task-group scope, but it
   still waits for that child to finish. Here that child is awaiting
   `writeTask.value`; canceling the wrapper child neither cancels the
   unstructured `writeTask` nor makes its `value` await return.[^1][^2][^3]
   Consequently, the outer `catch is TimeoutError` cannot run
   `writeTask.cancel()`/`pipe.close()` until the writer has already completed.
   A lost write-source wake or lost close signal can therefore wedge the test
   process exactly as before.

   I confirmed the task-group behavior with the installed Swift 6.2.4 toolchain:
   a 100 ms throwing child raced against a group child awaiting a separate
   non-cancellable two-second task, and the catch was reached only after
   **2.003 seconds**, not after 100 ms. Replace this structured task-group race
   with a timeout mechanism that can report timeout without awaiting the parked
   operation (for example, an XCTest expectation/continuation race), then cancel
   the writer and close the pipe from the reachable timeout path.

   The surrounding choices are otherwise sound: ten seconds is ample for the
   correct 512 KB path (the reviewed backpressure test completed in 0.264 s),
   and `ErrorBox` serializes set/get with `NSLock`, so no un-Sendable `Error?`
   crosses the task group and the value is read only after writer completion.
   The helper itself—not the deadline duration or `ErrorBox`—is the blocker.

2. **[RESOLVED] The backpressure test now guards repeated `EAGAIN` cycles and
   `disarmSource()` (`WriteSourceLifecycleTests.swift:158-216`).**

   The test first observes real backpressure, drains using bounded 16 KB reads,
   and requires at least two `onWouldBlock` transitions. It then awaits the
   writer before sampling `onSourceFire`, sleeps 150 ms, asserts the count is
   unchanged, and calls `close()` only afterward.[^2] Because this FIFO has one
   writer producing exactly 512 KB and the reader has consumed exactly 512 KB,
   the buffer is empty at the sample. If `disarmSource()` were deleted, the
   source would remain armed on that writable FIFO and repeatedly enter the
   handler, changing the lock-protected counter and failing the assertion.[^4]
   The handler increments the fire probe before signaling the parked writer,
   so the wake that precedes the correct disarm is counted before writer
   completion; I found no new counter race or credible false-failure window.

3. **[RESOLVED] The deinit probe no longer passes vacuously
   (`WriteSourceLifecycleTests.swift:274-299`).**

   The child retains only a weak reference after setting `pipe = nil` and now
   asserts that reference became `nil` before writing its sentinel.[^5] In the
   correct production implementation, the dispatch handler captures only the
   snapshotted probe and `PipeSignal`, not the actor, so no source-to-actor
   retain edge prevents synchronous deallocation.[^6] If a future handler
   captured `self`, the actor/source cycle would keep `weakPipe` non-`nil`, the
   child assertion would fail, and the parent would observe a nonzero exit.
   The focused run exercised the subprocess parent successfully.

4. **[INFO] The follow-up is production-neutral and adds no Sendable error
   (`f2ec537`; `WriteSourceLifecycleTests.swift:74-112`).**

   `git show f2ec537` lists only
   `Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift`.
   `git diff 26c3096..f2ec537` and the intervening log are empty for
   `ChunkedWritePipe.swift` and `ChunkedWritePipeError.swift`, so the production
   code approved in cycle 1 is unchanged. The two internal probes remain nil by
   default and their only callers are tests.[^6] The changed file compiled with
   no Sendable diagnostics. Its sole new diagnostic is the non-fatal
   `weak var 'weakPipe' was never mutated; consider changing to 'let'` warning
   at line 277; this has no behavioral impact and does not change the verdict.

## Cycle-1 P1 status

1. Multi-`EAGAIN` plus post-write `disarmSource()` guard: **resolved**.
2. Deadline-bounded writer completions: **not resolved** (Finding 1).

## Verification

- `swift test --filter GuessWhoMCPTransportTests` — **environment-blocked
  before manifest evaluation**, exit 1. First actionable error:
  `sandbox-exec: sandbox_apply: Operation not permitted`.
- `swift test --disable-sandbox --filter GuessWhoMCPTransportTests` —
  **passed**: 19 tests, 0 failures; selected tests completed in 2.326 s.
  `testBackpressureCyclesDisarmAndDeliverIntact` passed in 0.264 s, and
  `testDeinitWithoutCloseDoesNotAbort` passed in 0.212 s.
- Swift 6.2.4 task-group cancellation microprobe — **confirmed** the timeout
  scope waited 2.003 s for a non-cancellable operation despite a 100 ms
  throwing sibling.
- `git diff --check f2ec537^..f2ec537` — **passed**.
- Per request, no `xcodebuild` command was attempted.

[^1]: [Deadline helper](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.withDeadline)
[^2]: [Backpressure lifecycle regression test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testBackpressureCyclesDisarmAndDeliverIntact)
[^3]: [Close-while-parked regression test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testCloseWhileWriterParkedThrowsPipeNotOpened)
[^4]: [Write-source arm/wait/disarm loop](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.performWrite)
[^5]: [Self-relaunching deinit child](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testDeinitProbeChild)
[^6]: [Write-source probes, handler capture, and deinitializer](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe)
