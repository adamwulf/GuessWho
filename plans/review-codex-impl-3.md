# Focused re-review: MCP write-source deadline fix (cycle 3)

**Verdict: REQUEST-CHANGES**

Commit `396139b` fixes cycle 2's structured-concurrency hang: `awaitFlag`
polls a lock-guarded completion flag and neither it nor either caller awaits
`writeTask.value`. A lost wake therefore reaches `XCTFail` after the bounded
poll instead of blocking on task-group scope exit. One stated cleanup guarantee
is still incorrect, however: cancelling the test's `writeTask` does not cancel
the separate unstructured serialization task that is actually parked in
`PipeSignal.wait()`. That mismatch matters specifically on the lost-wake path
this test is meant to diagnose.

## Findings

1. **[P1] Timeout cancellation does not reach the parked writer
   (`WriteSourceLifecycleTests.swift:171-174, 195-198, 235-252`; `ChunkedWritePipe.swift:189-200, 237-262`).**

   The two test handles wrap `pipe.write(payload)`, but `ChunkedWritePipe.write`
   creates a second, unstructured `Task` for its serialization chain and awaits
   that task's value.[^1][^2][^3] The task parked in `PipeSignal.wait()` is this
   inner serialization task, not the outer test task. Cancelling the outer
   `writeTask` therefore does not invoke the parked task's cancellation handler,
   does not call `PipeSignal.signal()`, and leaves the inner task's
   `Task.isCancelled` false.[^4]

   I confirmed the exact nesting behavior with Swift 6.2.4 using an actor
   method that creates and awaits an inner unstructured task: after cancelling
   the outer handle, the probe printed `outer-cancelled=true` and
   `inner-cancelled=false`. In the backpressure timeout branch, the following
   `await pipe.close()` independently signals the waiter, so that branch does
   clean up.[^5] In the close-while-parked timeout branch, `close()` has already
   run; if its wake were genuinely lost, line 251's outer cancellation would
   not recover or terminate the parked inner writer. The test method itself is
   now bounded and will return its failure, so cycle 2's task-group hang is
   fixed, but the requirement that cancellation wake and unwind the parked
   writer is not met. Either arrange cancellation of the actual serialization
   task or revise the failure-path cleanup/claim so it does not rely on
   cancellation propagation that `Task {}` does not provide.

2. **[RESOLVED] `awaitFlag` removes the structured wait and bounds both test
   bodies (`WriteSourceLifecycleTests.swift:61-72, 87-98, 193-203, 248-257`).**

   `withDeadline`, task groups, and every `writeTask.value` await are gone from
   the file. At its default, `awaitFlag` performs 1,000 ten-ms sleeps, with a
   lock-guarded check before each sleep and one final check afterward.[^2] A never-set
   standalone probe completed in 12.404 seconds on this host (sleep overshoot
   makes this an iteration-bounded approximately-ten-second wait, not a strict
   wall-clock deadline). Neither call site enters a structured-concurrency
   scope that must await the writer before returning. The backpressure timeout
   cancels, closes, and fails; the close-while-parked timeout cancels and fails.

3. **[RESOLVED] Completion/error handoff remains synchronized and Sendable-safe
   (`WriteSourceLifecycleTests.swift:6-23, 100-107, 169-174, 200-203, 233-257`).**

   Each writer task increments `done` after either successful completion or
   the `catch`; there is no throwing path around that increment. Both reads of
   completion go only through `awaitFlag`, whose `Counter.count` read is locked.
   `ErrorBox` still serializes its stored `Error` with `NSLock`, and both helper
   objects are explicitly `@unchecked Sendable`, so no un-Sendable task result
   crosses a task boundary.[^2]

4. **[RESOLVED] Cycle-2 findings 2/3 still hold, and production is unchanged
   (`WriteSourceLifecycleTests.swift:205-219, 279-301`; `ChunkedWritePipe.swift:101-111, 138-142`).**

   The post-write quiet sample still occurs after the completion flag is
   observed and still guards `disarmSource()`.[^2][^3] The deinit child still
   drops the strong reference and asserts the weak reference is nil before
   writing its sentinel; `weak let` at line 280 removes the prior
   `[#WeakMutability]` warning without changing that test.[^2] `git show
   396139b` names only `WriteSourceLifecycleTests.swift`, and `git diff
   --exit-code 396139b^ 396139b --` for `ChunkedWritePipe.swift` and
   `ChunkedWritePipeError.swift` exits 0.

5. **[INFO] The ten-second completion budget is ample for the correct 512 KB
   path (`WriteSourceLifecycleTests.swift:94-98, 153-219, 224-258`).**

   The two requested suite runs completed the backpressure case in 0.318 and
   0.307 seconds, while close-while-parked completed in 0.026 and 0.030 seconds.
   The default poll therefore provides more than a 30x margin over the slower
   correct-path observation. Because `waitUntil` counts sleeps rather than
   comparing a clock, scheduler delay extends the effective deadline instead
   of shortening it. `awaitFlag` could return false for a semantically correct
   writer only if that writer still had not completed after at least roughly
   ten seconds of accumulated sleeps (for example, an extreme host stall); I
   found no credible correct-path mechanism near that budget.

## Cycle-2 finding status

1. Deadline helper could structurally await a parked writer: **resolved**.
2. Backpressure/disarm regression guard: **still resolved**.
3. Deinit weak-reference regression guard: **still resolved**; warning fixed.
4. New failure-path cancellation issue: **open** (Finding 1).

## Verification

- `swift test --filter GuessWhoMCPTransportTests` — **environment-blocked
  before manifest evaluation**, exit 1: `sandbox-exec: sandbox_apply:
  Operation not permitted`.
- `swift test --disable-sandbox --filter GuessWhoMCPTransportTests` — **passed
  twice**: 19 tests, 0 failures, 0 unexpected failures; selected tests took
  2.332 seconds on the clean build and 2.355 seconds on the cached rerun.
- The clean build emitted unrelated existing compiler warnings in other files:
  actor isolation, redundant nil coalescing, non-Sendable closure capture,
  never-mutated locals, deprecated MCP text construction, and optional-value
  string interpolation. The cached rerun emitted only two harness cache-access
  warnings for `~/Library/org.swift.swiftpm/{configuration,security}`. Neither
  run emitted `[#WeakMutability]` or any warning from
  `WriteSourceLifecycleTests.swift`.
- Swift 6.2.4 nested-task cancellation probe — **confirmed** outer cancellation
  did not cancel the actor method's inner unstructured task.
- Never-set 1,000 x 10 ms poll probe — **completed in 12.404 seconds**.
- `git diff --check 396139b^..396139b` — **passed**.
- Production-file diff for `ChunkedWritePipe.swift` and
  `ChunkedWritePipeError.swift` across `396139b^..396139b` — **empty**.
- Per request, no `xcodebuild` command was attempted.

[^1]: [Serialized write task](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.write)
[^2]: [Lifecycle regression tests and deadline flag](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests)
[^3]: [Writer cancellation check and EAGAIN wait](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.performWrite)
[^4]: [PipeSignal cancellation handler](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:PipeSignal.wait)
[^5]: [Pipe close wake](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.close)
