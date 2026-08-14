# Engineering review: MCP write-source CPU spin

**Verdict: REQUEST-CHANGES**

The sampled hot path and the source code support the plan's primary diagnosis:
the write dispatch source remains active while its FIFO is writable, and its
handler does not perform any write that would clear that condition. Gating the
write source around backpressure waits is the right direction. The proposed
state machine is balanced for one open/close generation, but the plan's
`close()` proof assumes that the actor cannot reopen before an old writer
continuation runs. The public API does permit that interleaving, which can send
old bytes to a new FIFO generation and can suspend a newly armed source. The
plan also needs a concrete, synchronized test hook and deterministic tests of
the EAGAIN and close-while-parked paths before implementation.

## Findings

1. **The root-cause diagnosis is correct and the idle-spin source inventory is
   complete (`ChunkedWritePipe.swift:111-125`,
   `CappedLineReadPipe.swift:132-143`; plan lines 41-70).**

   `ChunkedWritePipe.open()` activates a `DispatchSourceWrite` whose handler
   only records a `PipeSignal`; it does not write or otherwise make the FIFO
   non-writable. Consequently the handler is eligible again for as long as the
   FIFO has buffer space.[^1] The only other dispatch-descriptor source in the
   transport target is `CappedLineReadPipe`'s read source.[^2] There is no
   second write-source implementation or independent dispatch-source spin site
   in the reviewed transport sources. The secondary dispatch workloop stacks
   are therefore consistent with fallout from the repeatedly delivered write
   readiness event, not evidence of another source-level bug. Remove the
   inaccurate "future writability EDGES" comment as the plan proposes.[^3]

2. **Within one source generation, the proposed suspend/resume accounting is
   balanced (`ChunkedWritePipe.swift:79-85, 91-126, 128-197`; plan lines
   72-188).**

   The full path trace is:

   - Open installs an inactive source with `isSourceArmed == false`. A normal
     write never changes either state.
   - The first EAGAIN changes false to true and `resume()` activates the source.
     After `wait()` returns, disarm changes true to false and suspends it.
   - Later EAGAINs, including multiple EAGAINs in one payload, consume exactly
     one prior suspension with `resume()` and add exactly one with `suspend()`.
   - Concurrent `write()` calls have only one active `performWrite()` because
     each task awaits `lastWrite`; queued tasks do not concurrently manipulate
     the flag.[^4]
   - Close while idle resumes either the never-activated source or a suspended
     source, then cancels it. Close while a writer is parked sees an active
     source and cancels without an extra resume. Setting `source = nil` and the
     flag false makes the old writer's eventual disarm a no-op, provided no new
     source has been installed.
   - Deinit after open but before close likewise activates/resumes before
     cancel. Deinit after close sees no source. A live `performWrite()` retains
     the actor, so deinit cannot race that task.

   The plan should call the initial state **inactive**, not suspended. Modern
   dispatch documentation distinguishes an inactive source from an activated
   source with a positive suspension count; `resume()` happens to activate an
   inactive source for backward compatibility. The proposed Boolean safely
   conflates those two idle states only because both cleanup paths use
   `resume()` before cancellation.

3. **The close/reopen generation race invalidates the plan's close proof and
   must be fixed in the design (`ChunkedWritePipe.swift:91-92, 133-139,
   155-188`; plan lines 165-188).**

   `close()` sets `lastWrite = nil` and returns after waking a parked writer;
   it does not await that writer or mark the instance permanently closed.[^5]
   `open()` accepts the same actor again as soon as `fd` is negative.[^6] A
   legal interleaving is therefore:

   1. Writer A gets EAGAIN, arms source A, and parks.
   2. `close()` cancels source A, clears the stored source/flag, sets `fd = -1`,
      and signals writer A.
   3. Before A's continuation gets the actor, `open()` installs source B.
   4. A new writer B can arm source B and park under backpressure.
   5. Writer A resumes and calls the proposed unqualified `disarmSource()`.
      It sees the actor's *current* armed source B and suspends it. A can then
      loop on the new `fd` and write the remainder of the old payload into the
      new connection, while writer B is left waiting on a suspended source.

   Actor isolation prevents simultaneous memory access, but it does not make
   this reentrant sequence impossible. The plan must either (a) make a
   `ChunkedWritePipe` permanently one-shot after `close()`, matching current
   production call sites that construct a fresh pipe when reconnecting, or
   (b) add an explicit open-generation token/source identity, reject stale
   writers before both disarm and write, and keep `open()` unavailable while
   close drains the old `lastWrite` chain. Add a regression test for the
   chosen contract.

4. **`PipeSignal` does not lose the relevant wakeup, but its single-waiter and
   stale-signal properties should be stated precisely
   (`CappedLineReadPipe.swift:269-307`, `ChunkedWritePipe.swift:133-139,
   185-188`; plan lines 172-188).**

   The lock makes "signal before waiter registration" safe: it stores one
   pending bit, and `wait()` atomically consumes that bit or installs the
   continuation.[^7] Writability is persistent, so arming after EAGAIN also
   observes a FIFO that became writable in the gap. Repeated handler calls are
   coalesced into the same Boolean, so after disarm there can be at most one
   immediately consumed stale signal and one corresponding extra EAGAIN retry.
   Cancellation and close signals are also safe and may leave the same bounded
   stale bit. This remains correct only with one waiter; `lastWrite` supplies
   that invariant inside a generation. The generation race in finding 3 breaks
   the broader assumption by allowing old and new chains to share the same
   `PipeSignal`.

5. **Leaving the read source armed is correct for this fix, with a lifecycle
   qualification (`CappedLineReadPipe.swift:23-33, 115-159`; plan lines
   62-70).**

   The read pipe keeps a writer FD open, so an idle FIFO has neither bytes nor
   EOF readability. Its active read source therefore stays quiet, and it must
   remain able to wake a parked `readLine()` consumer.[^8] This source can
   still repeat if bytes are left in the kernel while no consumer drains them,
   because its event handler also only signals. That is not the reported idle
   condition, and the production contract says each open pipe has one consumer,
   but the plan should scope "safe" to that contract rather than claim that an
   always-armed read source is unconditionally non-spinning. No
   `CappedLineReadPipe` source change is warranted here.

6. **The held reader FD requirement is correct, but the preferred fire-counter
   test is under-specified (`PipeTransportTests.swift:1-45`;
   `ChunkedWritePipe.swift:87-102`; plan lines 197-220).**

   A nonblocking `O_WRONLY` FIFO open fails with ENXIO when no read endpoint is
   open, and `ChunkedWritePipe.open()` deliberately preserves that probe
   behavior.[^9] The test should therefore open and defer-close a raw
   `O_RDONLY | O_NONBLOCK` reader before opening the writer.

   However, `@testable import` alone does not create a "test-only counter."
   The current test target uses a normal import,[^10] and a plain actor property
   cannot be incremented synchronously from the dispatch queue's event handler.
   The plan must specify a race-free observation point—for example an internal
   initializer-injected `@Sendable` event callback backed by a lock in the
   test, or a lock-protected internal counter exposed through an actor method.
   It must count only write-source event-handler entries, not manual and cancel
   calls to `PipeSignal.signal()`. Because the fixed source is inactive during
   idle, the expected count is exactly zero before close; a loose `<= 2` bound
   unnecessarily permits regressions. A short inverted expectation or settle
   interval is still time-based, so "deterministic" is slightly overstated,
   although the old implementation's immediate continuous firing gives this
   test a wide practical margin. The process-wide `getrusage` option is much
   more vulnerable to parallel-test and unrelated runner CPU and should remain
   a manual fallback, not the automated regression gate.

7. **The existing large-message tests do not deterministically cover EAGAIN or
   the lifecycle transitions the plan relies on
   (`PipeTransportTests.swift:89-111`; plan lines 231-242).**

   `testConcurrentLargeRequestsFromTwoHelpersArriveIntact` uses actively
   draining readers on separate FIFOs and payloads of roughly 8 KB.[^11] It can
   pass without either writer observing EAGAIN, so it does not prove the new
   arm/wait/disarm path. Add focused tests that deliberately hold a reader open
   without draining until the writer is known to be parked, then:

   - drain in controlled increments to force more than one EAGAIN/wakeup cycle
     for one payload;
   - close while parked and assert the write finishes with the expected error;
   - exercise or reject close-then-reopen according to finding 3; and
   - let an opened writer deinitialize without explicit close so the
     resume-before-cancel fallback is covered (a subprocess test is preferable
     if the failure mode is a libdispatch process abort).

8. **The suspend/resume design remains the smallest reasonable production
   change after generation safety is added (`ChunkedWritePipe.swift:46-51,
   111-125, 167-197`; plan lines 72-168).**

   Recreating a one-shot write source for every EAGAIN avoids suspension-count
   bookkeeping, but makes descriptor ownership and close-vs-handler ordering
   harder: file-descriptor sources must not let close race an outstanding
   handler. Blocking `poll()` on a worker queue trades the spin for a parked
   thread and still needs a reliable shutdown wake. A larger redesign could
   move the pending-byte buffer and all writes onto the source's serial queue,
   activating readiness only while that buffer is nonempty. For this patch,
   keep the persistent source and guarded arm/disarm helpers, but bind every
   wait/disarm to a source generation (or make the object one-shot) and add the
   state-transition tests above.

[^1]: [Write source setup and handler](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^2]: [Read source setup and handler](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:CappedLineReadPipe.open)
[^3]: [Plan root-cause analysis](mcp-write-source-cpu-spin.md:41-60)
[^4]: [Write serialization and write loop](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.write)
[^5]: [Writer close implementation](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.close)
[^6]: [Writer open guard](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^7]: [PipeSignal implementation](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:PipeSignal)
[^8]: [Read loop and source lifecycle](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:CappedLineReadPipe.readLine)
[^9]: [Nonblocking writer-open behavior](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^10]: [Transport test imports and fixture](../Tests/GuessWhoMCPTransportTests/PipeTransportTests.swift:PipeTransportTests)
[^11]: [Concurrent large-request test](../Tests/GuessWhoMCPTransportTests/PipeTransportTests.swift:PipeTransportTests.testConcurrentLargeRequestsFromTwoHelpersArriveIntact)
