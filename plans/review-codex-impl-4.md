# Focused re-review: MCP writer-unwind fix (cycle 4)

**Verdict: APPROVE-WITH-CHANGES**

Commit `04ec77d` resolves cycle 3's functional P1. Both lifecycle tests now
launch an unbound outer `Task`, observe completion only through a bounded flag,
and use `close()`—not ineffective outer-task cancellation—to wake a parked
inner serialization task. I found no remaining hang path, race, Sendable issue,
or production change. The sole follow-up is a stale helper comment that still
describes the cancellation behavior this commit correctly removed.

## Findings

1. **[P2] `awaitFlag` still documents the removed cancellation cleanup
   (`WriteSourceLifecycleTests.swift:87-93`).**

   The helper says that a false result makes the caller cancel the writer and
   that `PipeSignal.onCancel` wakes the wait. Neither caller now cancels a task;
   both call `pipe.close()`, precisely because cycle 3 established that outer
   cancellation does not reach the inner serialization task.[^1] Update these
   two lines to say that the caller closes the pipe to signal the parked inner
   writer. This is documentation-only and does not weaken the functional fix.

2. **[RESOLVED] `close()` now unwinds the actually parked task end-to-end
   (`WriteSourceLifecycleTests.swift:167-202, 236-256`;
   `ChunkedWritePipe.swift:189-200, 216-262`;
   `CappedLineReadPipe.swift:273-305`).**

   Both test writers are fire-and-forget `Task {}` expressions with no retained
   outer handle and no `cancel()` call.[^2][^3] On a timeout,
   `ChunkedWritePipe.close()` runs actor-isolated while `performWrite` is
   suspended, latches `isClosed`, cancels/detaches the dispatch source, sets
   `fd = -1`, directly calls `writableSignal.signal()`, and clears
   `lastWrite`.[^4] `PipeSignal.signal()` either resumes the installed
   continuation or records a pending signal, so the wake is not lost even if
   close races the final waiter installation.[^5]

   The resumed inner serialization task returns from `PipeSignal.wait()`, its
   `disarmSource()` is a no-op because close detached the source, and the next
   loop iteration sees `fd < 0` and throws `WritePipeError.pipeNotOpened`.[^6]
   That completes the inner task; `ChunkedWritePipe.write()`'s `task.value`
   throws; the fire-and-forget outer task catches the error, stores it, and
   increments `done`. The direct signal in `close()` is sufficient; correctness
   does not depend on the dispatch source's asynchronous cancel handler also
   signaling.

3. **[RESOLVED] No test path structurally awaits the writer or can hang
   (`WriteSourceLifecycleTests.swift:61-98, 167-223, 236-262`).**

   The file contains no writer handle, `writeTask.cancel()`, task group, or
   writer `.value` await.[^1] `awaitFlag` performs a finite number of lock-safe
   polls. The backpressure receive loop uses a non-blocking fd, a finite 512 KB
   payload, and a bounded no-progress budget; after that, completion polling is
   bounded. Every timeout/error cleanup calls actor-reentrant `close()`, whose
   body contains no suspension point or dependency on writer completion.[^2][^4]
   A thrown sleep cancellation exits the test rather than parking it. Thus the
   test method can fail or throw, but cannot remain structurally joined to the
   fire-and-forget writer.

4. **[RESOLVED] Re-closing an already closed pipe is safe and idempotent
   (`WriteSourceLifecycleTests.swift:248-256`;
   `ChunkedWritePipe.swift:216-234`).**

   After the first close, `source == nil`, `fd == -1`, `isSourceArmed == false`,
   and `lastWrite == nil`. A second `await pipe.close()` repeats the `isClosed`
   assignment, skips both resource-close branches, repeats those terminal
   assignments, and signals `writableSignal` again.[^3][^4] `PipeSignal`
   coalesces an extra signal into its Boolean pending bit, so this cannot
   double-resume a continuation. The cleanup is safe whether the original wake
   was consumed, still pending, or genuinely missed by the writer.

5. **[RESOLVED] No warning, race, flakiness, or prior-test regression was
   introduced (`WriteSourceLifecycleTests.swift:6-23, 100-107, 148-223,
   264-306`).**

   Swift accepts the unbound `Task {}` result without an unused-result warning,
   and the reviewed test file compiled without any warning or Sendable
   diagnostic. `Counter` and `ErrorBox` still lock every cross-task access; the
   writer closure captures only Sendable actor/data and the two explicitly
   lock-guarded `@unchecked Sendable` holders.[^1] The repeated-`EAGAIN` and
   post-write quiet assertions still guard the arm/disarm behavior, while the
   deinit child still uses `weak let` and asserts deallocation before writing
   its sentinel.[^2][^7] `git show 04ec77d` names only the lifecycle test, and
   `ChunkedWritePipe.swift` plus `ChunkedWritePipeError.swift` are byte-for-byte
   unchanged from cycle 1's reviewed `8931b1d` state.

## Cycle-3 finding status

1. Timeout cancellation did not reach the parked inner writer: **resolved**.
2. Bounded completion polling/no structured writer await: **still resolved**.
3. Lock-safe completion/error handoff and Sendable safety: **still resolved**.
4. Disarm guard, deinit weak-reference guard, and `weak let`: **still resolved**.
5. New functional findings: **none**. One stale-comment P2 remains (Finding 1).

## Verification

- `swift test --filter GuessWhoMCPTransportTests` — **environment-blocked
  before manifest evaluation**, exit 1: `sandbox-exec: sandbox_apply:
  Operation not permitted`. It also emitted two harness cache-access warnings
  for `~/Library/org.swift.swiftpm/{configuration,security}`.
- `swift test --disable-sandbox --filter GuessWhoMCPTransportTests` —
  **passed twice**: 19 tests, 0 failures, 0 unexpected failures. The clean run's
  selected tests took 2.312 seconds; the cached rerun took 2.450 seconds.
- The clean build emitted existing warnings in unrelated production/test files
  (actor isolation, redundant nil coalescing, non-Sendable closure capture,
  never-mutated locals, deprecated MCP text construction, and optional-value
  interpolation). The cached rerun emitted only the two harness cache-access
  warnings. Neither run emitted an unused-`Task` result warning,
  `[#WeakMutability]`, or any warning from `WriteSourceLifecycleTests.swift`.
- `git diff --check 04ec77d^..04ec77d` — **passed**.
- Production-file diff from cycle 1's reviewed `8931b1d` through `04ec77d` for
  `ChunkedWritePipe.swift` and `ChunkedWritePipeError.swift` — **empty**.
- Per request, no `xcodebuild` command was attempted.

[^1]: [Lifecycle completion helper and synchronized handoff](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests)
[^2]: [Backpressure/disarm lifecycle test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testBackpressureCyclesDisarmAndDeliverIntact)
[^3]: [Close-while-parked lifecycle test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testCloseWhileWriterParkedThrowsPipeNotOpened)
[^4]: [Write-pipe close lifecycle](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.close)
[^5]: [Single-waiter wake primitive](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:PipeSignal)
[^6]: [Serialized write and EAGAIN loop](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.performWrite)
[^7]: [Deinit weak-reference child](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testDeinitProbeChild)
