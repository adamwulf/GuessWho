# Implementation verification — write-source CPU spin fix

**Reviewer:** `researcher` agent `agent-11715671` · **Date:** 2026-08-14
**Scope:** verify that the implementation on `agent/mcp-cpu-spin` realizes the
approved plan[^1] and that the tests guard the regressions. Review only — no
code changes.

**Method.** I read the full diff `git diff 8101c5b..HEAD` (4 files: the pipe,
the new error file, the two new test files; no other file changed). I read the
plan and all four prior review documents. I traced each lifecycle path by hand.
I ran the full suite: `swift test` from the repo root, exit code 0 —
**307 XCTest tests, 0 failures** plus **863 swift-testing tests in 81 suites,
0 failures**. All six new lifecycle tests and the idle-spin test passed. The
deinit subprocess parent test ran for 0.214 s and passed — it did not skip.

---

## Point 1 — every plan edit is realized: **CONFIRMED**

- **A1, create inactive / no pre-arm.** `open()` does not call `resume()` and
  does not pre-signal. The old `writeSource.resume()` + `signal.signal()`
  lines are gone, replaced by a comment that states the level-triggered
  rationale[^2].
- **A2, armed state + helpers.** `isSourceArmed` plus `armSource()` /
  `disarmSource()` match the plan text, including the guard pattern that
  keeps the suspend/resume count at 0 or 1[^3].
- **A3, arm around the wait.** The `EAGAIN, EWOULDBLOCK` branch is exactly
  `onWouldBlock?(); armSource(); await writableSignal.wait(); disarmSource()`.
  The success path never touches the source[^4].
- **A4, resume-before-cancel.** `close()` sets `isClosed = true` first, then
  resumes a not-armed source before `cancel()`, nils the source, resets
  `isSourceArmed`, sets `fd = -1`, and signals the waiter — the plan's exact
  order[^5]. `deinit` has the same fallback: `if !isSourceArmed {
  source.resume() }` then `cancel()`, else close a bare fd[^6].
- **B1, one-shot.** `private var isClosed` exists; `open()` throws
  `ChunkedWritePipeError.pipeClosed` before the `fd < 0` guard[^2].
- **Corrected error type.** The error is a transport-owned enum in its own new
  file. It is NOT a `WritePipeError` case, and no `extension WritePipeError`
  exists anywhere in `Sources/` or `Tests/` (verified by grep)[^7].
- **By-value probe capture.** `open()` snapshots `onSourceFire` into a local
  (`let onFire = onSourceFire`) and the dispatch handler captures only that
  local, exactly as the plan shows[^2]. `onWouldBlock` is not snapshotted, but
  it does not need to be: `performWrite` calls it directly on the actor, so no
  dispatch closure captures anything. This is safer than the plan's letter and
  equal to its intent (no actor retention, no isolation diagnostic); the code
  comment states this reasoning[^8].
- **TDD order.** Commit `240d588` added only the seam + Test 1 and recorded
  the RED result in its message: **417,266 fires in 300 ms** on the always-
  armed source. Commit `0b34d59` applied Parts A + B and turned it green
  (417,266 → 0). The seam-only commit changed no runtime behavior (nil probe,
  source still always-armed).

## Point 2 — test coverage matches the plan: **CONFIRMED with two minor GAPs**

Confirmed items:

- **Idle no-spin asserts exactly 0.** `XCTAssertEqual(fires, 0, …)` — not
  `<= 2`[^9]. The counter increments only inside the write-source event
  handler; the cancel handler and manual `signal()` calls never touch it[^2].
  The test also reads the counter BEFORE `close()`, so teardown cannot
  pollute it[^9]. With the gated code the count is deterministically 0 (no
  write ever arms the source), so the assertion cannot flake.
- **Close-while-parked asserts the exact error.** `guard case
  WritePipeError.pipeNotOpened? = result else { XCTFail }`[^10].
- **Reopen throws `pipeClosed`.** The catch clause matches only
  `ChunkedWritePipeError.pipeClosed`; any other error propagates and fails
  the test[^11].
- **Deinit subprocess is self-relaunching with a sentinel guard.** The parent
  finds the `xctest` runner (arg0, then `xcrun -f xctest`), relaunches the
  bundle filtered to the child test with the probe env var set, bounds the
  child at 60 s, and asserts `terminationReason == .exit`, status 0, AND that
  the sentinel file exists — the sentinel catches a mis-filtered child that
  runs zero tests yet exits 0[^12]. `Package.swift` is unchanged, as the plan
  requires.
- **Park detection is synchronized on `onWouldBlock`, bounded.** Both
  backpressure tests wait for `blocks.count >= 1` through `waitUntil`
  (500 × 10 ms ≈ 5 s cap) before they act, and the drain loop is bounded by
  an idle-read counter (~4 s without progress)[^13].

The two gaps, both in `WriteSourceLifecycleTests`:

- **GAP (minor) — multi-EAGAIN is not step-synchronized and not asserted.**
  The plan says: drain in small increments and wait for the NEXT
  `onWouldBlock` before each further increment, to force more than one
  EAGAIN cycle[^1]. The implemented test synchronizes only the FIRST park,
  then free-runs the drain and asserts `blocks.count >= 1` at the end[^13].
  With a 512 KB payload against the ~64 KB FIFO buffer, multiple park cycles
  are near-certain in practice, but the test neither forces nor asserts a
  second cycle, so a bug that only appears on the second arm/disarm round
  (for example an unguarded double-resume) is caught probabilistically, not
  deterministically.
- **GAP (minor) — no deadline around the final writer-completion awaits.**
  The plan (cycle-2 finding 7) requires a bounded deadline around EVERY
  writer completion so a lost wake fails fast instead of hanging[^14]. Both
  tests end with an unbounded `await writeTask.value`[^13][^10]. If a
  regression loses the wake, the drain loop exits after ~4 s but the awaited
  writer task never completes, and the suite hangs instead of failing. The
  scenario needs a broken fix to occur, and CI timeouts would still surface
  it, but the fail-fast property the plan asked for is not met on this one
  path.

Neither gap weakens what the tests DO prove (delivery integrity under real
backpressure, clean close-while-parked, one-shot, no-crash lifecycles). They
are hardening deltas, not correctness holes in the shipped fix.

## Point 3 — does each test have teeth? Per-test verdicts

- **`testIdleWriteSourceDoesNotSpin` — TEETH, proven empirically.** Revert
  Part A (restore `resume()` + pre-signal) and the level-triggered handler
  fires continuously; the recorded RED run measured 417,266 fires against an
  assertion of exactly 0. This is the headline regression guard.
- **`testReopenAfterCloseThrowsPipeClosed` — TEETH.** Remove the `isClosed`
  guard and `open()` succeeds again (the test still holds the reader fd, so
  the reopen would not ENXIO) → `XCTFail` fires. A different thrown error
  would also fail (specific catch clause)[^11].
- **`testCloseOfInactiveSourceRejectsSubsequentWrites` — TEETH (crash-style).**
  Remove resume-before-cancel from `close()` and the release of the inactive
  source aborts libdispatch — the test run crashes loudly. It also pins the
  write-after-close contract (`pipeNotOpened`)[^15]. Note: it would pass on
  the ORIGINAL pre-fix code (the source was always active then). That is
  correct — it guards the new close() path, not the spin.
- **`testBackpressureDeliversLargePayloadIntact` — TEETH, with the hang
  caveat.** It deterministically forces at least one real EAGAIN park
  (512 KB ≫ FIFO buffer, no draining until `onWouldBlock` fires) and proves
  byte-for-byte delivery through arm/wait/disarm cycles. An arm/disarm
  imbalance crashes it; a truncation fails it. But a never-armed regression
  (writer parks, no wake) makes it HANG at `await writeTask.value` rather
  than fail fast — the deadline gap above. It also passes on the pre-fix
  always-armed code, by design: it guards the new mechanism's delivery, not
  the spin.
- **`testCloseWhileWriterParkedThrowsPipeNotOpened` — TEETH.** It pins the
  exact contract the plan proves in its correctness notes: parked writer
  wakes, `disarmSource()` no-ops on the nil source, the loop sees `fd == -1`,
  throws `pipeNotOpened`; no crash, no stale write[^10]. The wake is
  deterministic (close() signals directly AND the cancel handler signals), so
  only a double regression could hang it — same unbounded-await caveat.
- **`testDeinitWithoutCloseDoesNotAbort` — TEETH for its target.** Remove the
  `deinit` resume-before-cancel and the child releases an inactive source →
  libdispatch abort → child dies by signal → the parent's
  `terminationReason == .exit` assertion fails. The sentinel closes the
  "filter matched nothing" false-pass hole[^12]. **Residual limitation:** if
  a future change makes the event handler capture the actor (a retain
  cycle), `deinit` never runs, the child exits 0, and this test passes
  vacuously — it cannot detect that its scenario stopped executing. A
  one-line hardening would close this: in the child, hold `weak var probe =
  pipe` and assert `probe == nil` after `pipe = nil`. Not a blocker — the
  current handler demonstrably captures only locals[^2] — but worth doing in
  a follow-up.
- **`testDeinitProbeChild` — no teeth by itself, by design.** In the normal
  run it returns immediately (env var unset). It only does work when the
  parent relaunches it. This is documented in the test and is the accepted
  cost of the no-new-target strategy[^12].

## Point 4 — production surface beyond the intended gating: **CONFIRMED clean**

- The two seams are `internal` (no access modifier on a member of a public
  actor) and reachable only through `@testable import`. Grep over `Sources/`
  and `App/` finds no production caller of `_setOnSourceFire` /
  `_setOnWouldBlock`; both properties are nil in production, so the probe
  calls are nil-checks[^16].
- The only new public API is `ChunkedWritePipeError` — required so callers
  can catch the reopen error, and sanctioned by the plan[^7].
- The only behavior changes callers can observe: (1) `open()` after `close()`
  now throws instead of silently reopening — Part B, intended; (2) the
  removed pre-arm signal means the first EAGAIN wait no longer wakes
  spuriously — Part A, intended. Both production call sites follow the
  one-shot contract already: `RelayConnection.connect()` constructs fresh
  announce/request pipes each call and `closePipes()` nils them[^17];
  `MCPPipeHost` constructs a fresh response writer per session and closes it
  at teardown[^18]. No caller reopens a closed instance.
- `CappedLineReadPipe` and `Package.swift` are untouched, as the plan
  requires. The read source stays always-armed, with the plan's
  single-consumer + keepalive rationale preserved in the plan document.

## Point 5 — unrealized plan claims / untested paths

- The two test gaps from Point 2 are the only plan items not realized to the
  letter (step-synchronized multi-EAGAIN; deadlines on writer-completion
  awaits).
- `onWouldBlock` capture differs from the plan's letter (no snapshot) but is
  strictly safer; realized in spirit (see Point 1).
- Untested code paths, all acceptable: the `deinit` bare-fd branch
  (`else if fd >= 0`) is defensive and unreachable today (`open()` sets `fd`
  and `source` together; `close()` clears both)[^6]; the `EINTR` and
  `written == 0` continues predate this fix; the plan's `getrusage` CPU check
  is manual-only by design and is correctly absent.
- The plan's Verification step 3 (Activity Monitor idle check of app + CLI)
  is a manual step outside the test suite; it remains for a human to run.

## Overall assessment

**APPROVE.** The implementation realizes every structural edit of the
approved plan faithfully — gating, one-shot, resume-before-cancel on both
teardown paths, the transport-owned error, and the by-value capture — and the
TDD record (417,266 → 0) proves the headline test measures the real spin. The
full suite is green: 307 XCTest + 863 swift-testing tests, 0 failures. The
two findings are minor test-hardening deltas (deterministic multi-EAGAIN
forcing; bounded awaits on writer completion) plus one optional
deinit-deallocation assert; none blocks merge, and none affects production
behavior.

[^1]: [Approved plan, regression-test section](mcp-write-source-cpu-spin.md:368-439)
[^2]: [Gated source setup and handler capture](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^3]: [Arm/disarm helpers](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.armSource)
[^4]: [EAGAIN branch of the write loop](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.performWrite)
[^5]: [One-shot close with resume-before-cancel](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.close)
[^6]: [Deinit fallback](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.deinit)
[^7]: [Transport-owned reopen error](../Sources/GuessWhoMCPTransport/ChunkedWritePipeError.swift:ChunkedWritePipeError)
[^8]: [onWouldBlock seam declaration and rationale](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.onWouldBlock)
[^9]: [Idle no-spin assertion](../Tests/GuessWhoMCPTransportTests/WriteSourceIdleSpinTests.swift:WriteSourceIdleSpinTests.testIdleWriteSourceDoesNotSpin)
[^10]: [Close-while-parked test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testCloseWhileWriterParkedThrowsPipeNotOpened)
[^11]: [Reopen contract test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testReopenAfterCloseThrowsPipeClosed)
[^12]: [Self-relaunching deinit test, parent + child](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testDeinitWithoutCloseDoesNotAbort)
[^13]: [Backpressure delivery test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testBackpressureDeliversLargePayloadIntact)
[^14]: [Cycle-2 codex review, finding 7](review-codex-cpu-spin-2.md:103-112)
[^15]: [Close-of-inactive-source test](../Tests/GuessWhoMCPTransportTests/WriteSourceLifecycleTests.swift:WriteSourceLifecycleTests.testCloseOfInactiveSourceRejectsSubsequentWrites)
[^16]: [Internal test seams](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe._setOnSourceFire)
[^17]: [Relay pipe construction and teardown](../Sources/GuessWhoMCPTransport/RelayConnection.swift:RelayConnection.connect)
[^18]: [Host per-session response writer](../Sources/GuessWhoMCPTransport/MCPPipeHost.swift)
