# Engineering review: MCP write-source CPU-spin implementation

**Verdict: APPROVE-WITH-CHANGES**

The production fix is sound: I found no suspend/resume imbalance, reopen hole,
lost wakeup, probe race, or actor-retention cycle in the reviewed transport
code. The requested changes are confined to the hardening tests. In
particular, the committed backpressure test does not prove the approved
multi-`EAGAIN`/disarm behavior and two writer-completion waits can still hang
the suite indefinitely.

## Findings

1. **[P1] The backpressure test does not guard either multi-`EAGAIN` or the
   return-to-idle disarm (`WriteSourceLifecycleTests.swift:136-173`;
   `ChunkedWritePipe.swift:256-262`).**

   `testBackpressureDeliversLargePayloadIntact` waits only for
   `blocks.count >= 1`, drains all currently available bytes on each pass, and
   ends by asserting only `>= 1`.[^1] It therefore proves one arm/wake and
   payload integrity, not multiple arm/wait/disarm cycles. More importantly,
   deleting only the `disarmSource()` call would restore a permanent write
   source spin after the first real backpressure event, while the idle test
   (which sends no data) and every lifecycle test here could still pass: the
   source would remain active, delivery would continue, and `close()` would
   cancel it as an already-armed source.[^2][^3]

   Change this test to force and observe at least two distinct `onWouldBlock`
   transitions with stepwise drains, and then prove that the source is quiet
   after the completed write. That makes both the multi-`EAGAIN` state
   transition and the load-bearing disarm independently regression-sensitive.

2. **[P1] The writer completions are not deadline-bounded
   (`WriteSourceLifecycleTests.swift:155-168, 192-200`).**

   The receive loop in `testBackpressureDeliversLargePayloadIntact` stops after
   its no-progress budget, but it then awaits `writeTask.value` without a
   timeout. A lost wake leaves that task parked forever, so the nominal loop
   bound does not bound the test. `testCloseWhileWriterParkedThrowsPipeNotOpened`
   likewise awaits its writer without a deadline after `close()`.[^1][^4]
   Race each writer completion against a real timeout (and cancel/close during
   timeout cleanup) so a missed dispatch or close signal fails instead of
   wedging the test process.

3. **Production source accounting is balanced on every reviewed path
   (`ChunkedWritePipe.swift:47-56, 101-142, 148-187, 189-201, 216-272`).**

   `open()` installs a never-activated source with `isSourceArmed == false`;
   ordinary writes do not touch it. Each `EAGAIN` changes false → true before
   `resume()`, waits, then changes true → false before `suspend()`. Multiple
   `EAGAIN`s repeat that balanced pair. `lastWrite` serializes concurrent
   callers, so only one `performWrite` can manipulate the source at a time;
   the existing concurrent-one-writer test also passes.[^2][^5]

   `close()` first latches one-shot state, then resumes only an idle
   inactive/suspended source, cancels, detaches the source, invalidates the fd,
   wakes a waiter, and clears the task chain. A parked writer sees an already
   active source, so close does not over-resume; after wake, its disarm is a
   no-op and its next iteration throws `pipeNotOpened`. The reopen guard is the
   first operation in `open()`, so no second source generation can be
   installed.[^3][^6] In `deinit`, false correctly covers both never-activated
   and activated-then-suspended states; true needs no resume. A parked writer's
   task retains the actor, so deinit cannot race the active wait.[^7] I found no
   path that can double-resume or release an inactive/suspended source.

4. **The test seams and wake primitive are race-safe and production-neutral
   (`ChunkedWritePipe.swift:58-69, 115-124, 169-180, 256-262`;
   `CappedLineReadPipe.swift:269-306`).**

   Both probes default to `nil` and are internal. `onSourceFire` is copied to
   `onFire` before the dispatch closure is installed, so the handler captures
   the callback and `PipeSignal`, not the actor; this avoids the retention
   cycle that would invalidate the deinit probe. `onWouldBlock` is read only on
   the actor, while the lifecycle counter serializes cross-thread state with
   `NSLock`.[^8][^9] `PipeSignal` atomically consumes a pending bit or installs its
   sole continuation, so signal-before-wait is retained; repeated events are
   intentionally coalesced. Level-triggered writability covers the
   `EAGAIN`-to-arm window, and close's direct signal covers the asynchronous
   cancel-handler window.[^10]

5. **The remaining focused tests have the intended regression sensitivity
   (`WriteSourceIdleSpinTests.swift:50-74`;
   `WriteSourceLifecycleTests.swift:99-132, 178-204, 206-323`).**

   The idle probe asserts exactly zero handler entries, so it directly guards
   the original always-armed-at-open bug.[^11] Reopen asserts the exact new
   `ChunkedWritePipeError.pipeClosed` contract; inactive close would process-
   abort if its pre-cancel resume were removed; and parked close observes a real
   `EAGAIN` before asserting the exact `pipeNotOpened` result.[^4][^6][^12] The
   self-relaunching deinit test has a 60-second parent deadline, asserts normal
   exit, writes a sentinel only after the child scenario runs, and skips when it
   cannot locate a usable XCTest runner. It ran rather than skipped in this
   review, and the sentinel assertion passed.[^13]

## Verification

- `swift test` — **environment-blocked before manifest evaluation**. First
  actionable error: `sandbox-exec: sandbox_apply: Operation not permitted`.
  This is SwiftPM's nested sandbox, not a compiler or test diagnostic.
- `swift test --disable-sandbox` — compiled the reviewed transport code and ran
  the suite, but the overall command exited 1 in unrelated filesystem-backed
  tests (55 issues in the 863-test swift-testing run). The first observed
  failure was an inability to open a temp-directory `Favorites.json`. Reviewed
  transport sources emitted no diagnostics.
- `swift test --disable-sandbox --filter GuessWhoMCPTransport` — **passed**:
  19 tests, 0 failures. This includes the idle-spin, lifecycle, concurrent
  write, close-while-parked, and self-relaunching deinit tests.
- `xcrun simctl list devices available` — **environment-blocked**; no installed
  device could be selected because CoreSimulatorService was unavailable. First
  actionable errors: failure to open the CoreSimulator log (`Operation not
  permitted`) and `CoreSimulatorService connection became invalid`.
- `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination
  'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/DerivedData
  build` — **environment-blocked before `CompileSwift`**, exit 143. The first
  errors were failure to start the FSEvents stream and CoreSimulatorService
  invalidation; there were no project-source diagnostics.
- `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination
  'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedData build`
  — **environment-blocked before `CompileSwift`**, exit 143, by the same
  CoreSimulator/FSEvents restrictions. A generic simulator destination was used
  because simulator discovery itself was blocked; the app target therefore
  could not be independently compile-confirmed in this harness.
- `git diff --check 8101c5b..HEAD` — **passed**.

[^1]: [Backpressure lifecycle regression test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testBackpressureDeliversLargePayloadIntact)
[^2]: [Write-source EAGAIN arm/wait/disarm loop](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.performWrite)
[^3]: [Write-source close lifecycle](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.close)
[^4]: [Close-while-parked regression test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testCloseWhileWriterParkedThrowsPipeNotOpened)
[^5]: [Concurrent writes on one writer regression test](../Tests/GuessWhoMCPTransportTests/ReadPipeDeliveryTests.swift:ReadPipeDeliveryTests.testConcurrentMessagesOnOneWriterDoNotInterleave)
[^6]: [One-shot open guard](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^7]: [Write-source deinitializer](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.deinit)
[^8]: [Write-source test probes and handler capture](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe)
[^9]: [Lock-guarded lifecycle-test counter](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:Counter)
[^10]: [Single-waiter signal implementation](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:PipeSignal)
[^11]: [Idle write-source regression test](../Tests/GuessWhoMCPTransportTests/WriteSourceIdleSpinTests.swift:WriteSourceIdleSpinTests.testIdleWriteSourceDoesNotSpin)
[^12]: [One-shot error contract](../Sources/GuessWhoMCPTransport/ChunkedWritePipeError.swift:ChunkedWritePipeError)
[^13]: [Self-relaunching deinit regression test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testDeinitWithoutCloseDoesNotAbort)
