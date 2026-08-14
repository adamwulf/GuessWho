# Engineering review cycle 2: MCP write-source CPU spin

**Verdict: APPROVE-WITH-CHANGES**

The revised design closes the cycle-1 blocker. Once `close()` permanently sets
`isClosed` and `open()` checks it before considering the descriptor state, a
closed `ChunkedWritePipe` can never acquire source B. A stale writer from
source A can therefore only wake into `source == nil` and `fd == -1`; its
disarm is a no-op and its next loop iteration fails. The actor executes the
proposed `close()` body without suspension, so a woken continuation cannot
observe its intermediate assignments.[^1][^2]

The plan should not be implemented literally yet. It names an error case that
cannot be added in this repository, leaves the event probe vulnerable to an
actor retain cycle/isolation error unless it is captured by value, and does
not provide deterministic synchronization or time bounds for the backpressure
tests. These are bounded design edits rather than a rejection of the gating
approach.

## Cycle-1 findings

1. **RESOLVED — diagnosis and source inventory**
   (`plans/mcp-write-source-cpu-spin.md:41-107`;
   `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:91-125`;
   `Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:107-143`).

   The revision corrects the edge-triggered explanation, removes both the
   unconditional `resume()` and manual pre-signal in Edit A1, distinguishes
   healthy writability from dead-reader EOF, and correctly limits the app's
   hot-writer count to one per connected helper rather than a fixed two. It
   also inventories the read source separately.[^3][^4]

2. **RESOLVED — one-generation source accounting**
   (`plans/mcp-write-source-cpu-spin.md:118-210,258-269`;
   `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:79-125,155-188`).

   Edits A1–A4 now name the initial state as inactive, guard every
   resume/suspend with `isSourceArmed`, and resume before cancellation on both
   cleanup paths. The proposed deinitializer is correct in both resting
   sub-states: `false` means either never-activated/inactive or
   activated-then-suspended, and one `resume()` activates or balances those
   states respectively; `true` is already active and needs no resume before
   cancel.[^5]

3. **RESOLVED — close/reopen generation race (cycle-1 blocker)**
   (`plans/mcp-write-source-cpu-spin.md:212-256`;
   `Sources/GuessWhoMCPTransport/RelayConnection.swift:95-182`;
   `Sources/GuessWhoMCPTransport/MCPPipeHost.swift:146-211`).

   The one-shot contract makes the reported interleaving structurally
   impossible, provided `isClosed = true` remains the first operation of
   `close()` and the guard remains the first operation of `open()`. There is
   no await in the proposed close body, so there is no actor-reentrancy window
   between marking closed, detaching the source, invalidating `fd`, and waking
   the writer. The complete production-use search finds only three
   constructions: relay announce and request writers are newly constructed
   in each `connect()` and closed then nilled by `closePipes()`; the host
   constructs a response writer for each new session and destroys it during
   teardown. No production caller reopens a closed instance.[^6][^7]

4. **RESOLVED — `PipeSignal` wakeup and stale-bit analysis**
   (`plans/mcp-write-source-cpu-spin.md:270-282`;
   `Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:273-307`;
   `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:128-139`).

   The revision now states the single-waiter condition, signal-before-wait
   behavior, Boolean coalescing, and the bounded one-retry cost of a stale
   signal. One-shot lifetime preserves that condition across close by
   preventing a new write chain and source from sharing the old signal.[^8]

5. **RESOLVED — read-source lifecycle qualification**
   (`plans/mcp-write-source-cpu-spin.md:91-107`;
   `Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:23-33,107-159`).

   The revision no longer calls an armed read source unconditionally safe. It
   correctly scopes quiet idle behavior to the existing single draining
   consumer plus the pipe's keepalive writer FD, and leaves the read source
   unchanged.[^4]

6. **PARTIALLY RESOLVED — idle-fire observation seam**
   (`plans/mcp-write-source-cpu-spin.md:118-126,299-326`;
   `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:53-125`).

   The revision supplies the missing synchronized shape: a `@Sendable`
   callback, a lock-backed test counter, event-handler-only counting, and an
   exact-zero assertion before close. However, Edit A1's literal
   `{ onSourceFire?(); signal.signal() }` is incomplete when `onSourceFire` is
   an actor property. `open()` must first copy it to a local value and the
   dispatch closure must capture that value, as the current implementation
   already does for `writableSignal`. Capturing `self.onSourceFire` from the
   dispatch handler risks an isolation diagnostic and creates
   actor → source → handler → actor retention, which would defeat the deinit
   test. Keep the public initializer unchanged if practical and expose the
   probe through an internal test initializer; production should always
   capture `nil`. `@Sendable` plus the test counter's lock makes the intended
   test use race-free, but `@Sendable` alone is not a substitute for the
   lock.[^9]

7. **PARTIALLY RESOLVED — deterministic lifecycle coverage**
   (`plans/mcp-write-source-cpu-spin.md:328-356`;
   `Tests/GuessWhoMCPTransportTests/PipeTransportTests.swift:89-111`).

   The revision adds every missing scenario, but “do not drain,” “drain in
   small increments,” and “park a writer” are still actions rather than an
   observable synchronization protocol. A scheduling delay could let the
   assertions run before the writer reaches EAGAIN, while a missed wake could
   hang the suite indefinitely. Add a lock/expectation-backed `onWouldBlock`
   probe at the EAGAIN transition, wait for its first and subsequent counts
   before each controlled drain/close, and put a deadline around every writer
   completion. Assert the close-while-parked error specifically, not merely
   “the expected error.” The existing actively drained ~8 KB round trip still
   cannot prove any EAGAIN occurred.[^10]

8. **RESOLVED — selected production design**
   (`plans/mcp-write-source-cpu-spin.md:109-282,393-405`).

   With the one-shot lifetime added, guarded suspend/resume remains the
   smallest sound production change among the alternatives considered. The
   remaining changes in this review concern implementability and test
   determinism, not the selected readiness design.[^1]

## New findings

9. **The proposed `WritePipeError.pipeClosed` cannot be added in this
   repository** (`plans/mcp-write-source-cpu-spin.md:243-251,358-365`;
   `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:1-5,91-102`;
   `Package.swift:80-87,145-150`).

   `WritePipeError` is declared by the pinned `EasyMacMCP` dependency, and
   Swift enums cannot gain cases in an extension. There is no
   `WritePipeError.swift` in this package to edit. Define a transport-owned
   error such as `ChunkedWritePipeError.pipeClosed` (and decide whether to
   migrate the existing error surface), or reject reopen with an existing
   error and test that exact contract. Updating the dependency itself would
   be a materially larger, separately pinned change and is unnecessary for
   generation safety.[^11][^12]

10. **The event probe must not retain the actor or become a production
    behavior hook** (`plans/mcp-write-source-cpu-spin.md:118-126,299-314`;
    `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:53-125`).

    Snapshot the optional callback into a local before installing the event
    handler, and keep the callback internal/test-only if possible. In the
    test, the captured counter must be a lock-guarded Sendable reference and
    the callback must do only the increment/expectation notification. With a
    local `nil` snapshot in production, the optional call does not introduce a
    data race or meaningful behavioral change; exposing arbitrary callbacks
    publicly or capturing the actor would make that conclusion false.[^9]

11. **Edit A4's ordering is safe, but its invariants should be explicit**
    (`plans/mcp-write-source-cpu-spin.md:181-210`;
    `Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:155-188`).

    `isClosed` first prevents future opens. Resume-before-cancel balances the
    dispatch state; setting `source = nil` makes stale disarm a no-op; setting
    `fd = -1` before signaling ensures a woken writer cannot perform another
    write. The source's cancel handler closes its captured `opened` descriptor,
    so delayed handler execution does not depend on the actor's `fd` value.
    The direct signal is required because the cancel handler is asynchronous.
    Clearing `lastWrite` before old tasks finish permits post-close write tasks
    to run independently, but they can only observe `fd == -1`; with reopen
    forbidden this is harmless. Do not add an await anywhere inside this
    sequence.[^2][^5]

12. **The subprocess test is useful and implementable, but the target/build
    contract is not yet specified** (`plans/mcp-write-source-cpu-spin.md:344-370`;
    `Package.swift:140-168`).

    The in-process close-of-inactive test does not execute the deinitializer's
    fallback branch, and libdispatch abort cannot be asserted in-process, so a
    child-process check is justified if deallocate-without-close remains a
    supported safety path. A tiny executable can work in this SwiftPM package,
    but the plan must add the executable target/product to `Package.swift`,
    ensure the test invocation actually builds it, and define a configuration-
    and-triple-independent way for XCTest to locate it. A self-relaunching,
    narrowly filtered XCTest helper is another option. The current “target or
    fallback” wording conflicts with Verification step 2's unconditional
    statement that Tests 2–3 pass; select one approach before implementation
    and state exactly how it is invoked.[^13]

## Required plan changes before implementation

1. Replace the impossible foreign-enum edit with a repository-owned reopen
   error contract and update the reopen assertion.
2. Specify value capture and visibility for `onSourceFire`; add an explicit
   EAGAIN/park observation seam rather than inferring parking from timing.
3. Add bounded deadlines and stepwise synchronization to the multi-EAGAIN and
   close-while-parked tests.
4. Choose the subprocess strategy and document its SwiftPM target/build/path
   mechanics, or explicitly waive that test and make Verification reflect the
   waiver.

[^1]: [Revised plan, write-source state machine and correctness notes](mcp-write-source-cpu-spin.md:109-282)
[^2]: [Writer close and write loop](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.close)
[^3]: [Writer source setup](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^4]: [Read source setup and lifecycle contract](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:CappedLineReadPipe.open)
[^5]: [Writer deinitializer](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.deinit)
[^6]: [Relay writer construction and teardown](../Sources/GuessWhoMCPTransport/RelayConnection.swift:RelayConnection.connect)
[^7]: [Host response-writer session lifecycle](../Sources/GuessWhoMCPTransport/MCPPipeHost.swift:MCPPipeHost.setupSession)
[^8]: [Single-waiter signal implementation](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:PipeSignal)
[^9]: [Current actor initializer and source-handler capture pattern](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^10]: [Current concurrent large-request test](../Tests/GuessWhoMCPTransportTests/PipeTransportTests.swift:PipeTransportTests.testConcurrentLargeRequestsFromTwoHelpersArriveIntact)
[^11]: [Pinned EasyMacMCP package dependency](../Package.swift:80-87)
[^12]: [EasyMacMCP `WritePipeError` declaration at the pinned revision](https://github.com/adamwulf/mcp-template/blob/3cb7bec338efeee0b8d4fce338e9e61b755f1066/Sources/EasyMacMCP/WritePipe.swift)
[^13]: [Current SwiftPM transport and test-target declarations](../Package.swift:140-168)
