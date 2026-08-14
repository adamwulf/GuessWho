# Researcher review — MCP write-source CPU spin plan

**Reviewer:** researcher `agent-56811bef` · **Date:** 2026-08-13
**Plan under review:** [`mcp-write-source-cpu-spin.md`](mcp-write-source-cpu-spin.md)
**Scope:** Verify the factual and semantic claims in the plan against
authoritative sources. No source files were changed.

Sources used: the macOS SDK dispatch headers and man pages on this machine
(`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`), the libdispatch
implementation (swift-corelibs-libdispatch mirrors the Darwin sources), the
kqueue man page, and Apple's archived Concurrency Programming Guide.

---

## Point 1 — Write sources are level-triggered; an idle FIFO is always writable

**Verdict: CONFIRMED.**

Three independent sources support the claim:

1. **kqueue filter semantics.** `EVFILT_WRITE` "returns whenever it is
   possible to write to the descriptor. For sockets, pipes and fifos, `data`
   will contain the amount of space remaining in the write buffer."[^1] The
   filter reports current state. Only `EV_CLEAR` changes a filter to
   transition (edge) reporting: "After the event is retrieved by the user,
   its state is reset. This is useful for filters which report state
   transitions instead of the current state."[^2]
2. **libdispatch registration flags.** libdispatch registers
   `DISPATCH_SOURCE_TYPE_WRITE` with
   `.dst_filter = EVFILT_WRITE` and
   `.dst_flags = EV_UDATA_SPECIFIC|EV_DISPATCH|EV_VANISHED` — **no
   `EV_CLEAR`**.[^3] `EV_DISPATCH` only disables the knote for the duration
   of one delivery. After the event handler returns, the invoke path re-arms
   the knote with `_dispatch_unote_resume(dr)` unless the source is
   suspended or cancelled.[^4] A re-armed level filter on a still-writable
   fd fires again at once. The result is one handler invocation after
   another for as long as the source stays resumed — the busy loop the plan
   describes.
3. **Apple guidance.** The Concurrency Programming Guide's write-descriptor
   example cancels the write source after the data is written "to prevent it
   from being called again."[^5] The guide thus expects a write source to
   keep calling the handler when it stays armed.

An idle FIFO is writable: its buffer is empty, and the write low-water mark
is 1 byte (libdispatch sets `.dst_data = 1` with `NOTE_LOWAT`).[^3] The SDK
header describes the source as monitoring "available buffer space to write
bytes."[^6] Note also the degenerate case: when the read end disappears,
`EVFILT_WRITE` sets `EV_EOF` and still fires,[^1] so the source spins in
that state too. Either way, an always-armed write source on an idle FIFO
busy-loops.

The plan also says the in-code comment ("The source fires only on future
writability EDGES") is wrong. Correct — the comment at
`ChunkedWritePipe.open()`[^7] contradicts the level semantics above.

## Point 2 — Read-source asymmetry: an armed read source on an idle fd stays quiet

**Verdict: CONFIRMED, with one condition the code already satisfies.**

`EVFILT_READ` "returns whenever there is data available to read," and for
fifos/pipes "returns when there is data to read."[^8] No data → no event →
no handler invocation. The Concurrency Programming Guide states the level
behavior for read sources explicitly: a read source "schedules its event
handler repeatedly **while there is still data to read**."[^5] An idle FIFO
holds no data, so the armed read source costs nothing.

The condition: `EVFILT_READ` on a FIFO **does** fire persistently once the
last writer disconnects (`EV_EOF`).[^8] `CappedLineReadPipe` prevents this
state by design — it holds a keepalive `O_WRONLY` fd on its own FIFO so the
kernel writer count never reaches zero.[^9] With that keepalive in place,
"leave the read source armed" is safe, as the plan says. The plan's
instruction to not touch the read source is sound.

## Point 3 — GCD lifecycle rules the fix depends on

### 3a — Releasing the last reference to a suspended source crashes

**Verdict: CONFIRMED.**

The documented contract: "The result of releasing all references to a
dispatch object while in an inactive or suspended state is undefined."[^10]
In practice the "undefined" result is a deliberate crash. The libdispatch
dispose path checks the state and calls
`DISPATCH_CLIENT_CRASH(dq_state, "Release of a suspended object")`.[^11]
`DISPATCH_CLIENT_CRASH` prefixes the message with
`"BUG IN CLIENT OF LIBDISPATCH: "`,[^12] which yields the exact crash string
the plan quotes.

One nuance the plan does not state: a source that was **never resumed at
all** is in the *inactive* state, not the plain suspended state, and its
release crashes with the sibling message `"Release of an inactive
object"`.[^11] Same crash class, different string. This matters for the
fix's never-armed path (source created, no `EAGAIN` ever, then closed): the
SDK header says "A source must have been activated before being
disposed."[^13] The plan's Edit 4 (resume-before-cancel in `close()` and
`deinit`) covers this case, because `dispatch_resume()` on an inactive
source is documented to act as `dispatch_activate()`.[^14]

### 3b — `cancel()` on a suspended source defers the cancel handler

**Verdict: CONFIRMED.**

The `dispatch_object(3)` man page states it directly: "**Important:**
suspension applies to all aspects of the dispatch object life cycle,
including the finalizer function and **the cancellation handler**."[^10]
The implementation matches: the source invoke path returns early while the
source is suspended, before cancellation processing runs.[^4] The
`dispatch_source_create(3)` man page adds the never-resumed variant: "If a
source is canceled before the first time it is resumed, its event handler
will never be called. (In this case, note that the source must be resumed
before it can be released.)"[^15]

So the plan's consequence holds: the cancel handler is what closes the fd
(`ChunkedWritePipe.open()` sets it[^7]), and a suspended-then-cancelled
source does not run that handler until a resume — the fd stays open. In
practice a suspended source that is then released crashes first (3a), so
"crash" is the more likely failure than a silent leak; the leak occurs only
if the object is kept alive while suspended forever. Either way,
resume-before-cancel is the correct rule.

### 3c — Suspend/resume is a balanced counter that must be re-balanced before release

**Verdict: CONFIRMED.**

"Calls to dispatch_suspend() must be balanced with calls to
dispatch_resume()."[^16] "dispatch_resume() … consumes suspension counts.
… If the specified object has zero suspension count and is not an inactive
source, this function will result in an assertion and the process being
terminated."[^14] And the release-side rule: "it is important to balance
calls to dispatch_suspend and dispatch_resume such that the dispatch object
is fully resumed when the last reference is released."[^10] Over-resume
terminates the process; under-resume trips 3a. The plan's `isSourceArmed`
guard is the right shape for keeping the count at 0 or 1.

## Point 4 — A fresh DispatchSource starts suspended (inactive)

**Verdict: CONFIRMED, with a terminology nuance.**

The older man page says: "Newly created sources are created in a suspended
state. … the source must be activated by a call to dispatch_resume before
any events will be delivered."[^15] The current SDK header uses the newer
term: "Dispatch sources are created in an **inactive** state. … a call must
be made to dispatch_activate() in order to begin event delivery."[^13]
Swift's `DispatchSource.makeWriteSource` wraps `dispatch_source_create`, so
the same applies. Either way the plan's operational assumption is right:
not calling `resume()` leaves the source inert and no events are delivered.

The nuance (also flagged under 3a): "inactive" is a distinct sub-state of
suspended. It changes the crash string on a bad release and it is why the
header warns "A source must have been activated before being
disposed."[^13] The plan's Edit 4 resume-before-cancel handles it, but the
plan's text ("created in the suspended state") slightly understates the
rule — reviewers of the implementation should know both states exist.

## Point 5 — Do the `sample` stacks fit the diagnosis?

**Verdict: CONFIRMED as consistent; the raw samples themselves were not
available for re-inspection.**

The quoted hot stack —
`_dispatch_source_invoke → _dispatch_source_latch_and_call →
_dispatch_client_callout → PipeSignal.signal()` on a queue labeled
`com.milestonemade.guesswho.mcp.pipe-write` — is exactly the libdispatch
event-delivery path. `_dispatch_source_latch_and_call` is the real internal
function that latches pending data and invokes the client event
handler,[^17] and `PipeSignal.signal()` is the write source's event handler
block.[^7] The `pipe-write` queue label is created only in
`ChunkedWritePipe.open()`;[^7] the read pipe uses a distinct `pipe-read`
label.[^9] So the samples pin the CPU burn to write-source event delivery,
which matches an always-armed level-triggered write source and the
per-invocation re-arm cost (`_dispatch_workloop_worker_thread` /
`_dispatch_event_loop_merge` churn) described in the plan.

Alternative explanations, checked:

- **Read-source spin.** Excluded by the queue label — the hot queues are
  `pipe-write`, not `pipe-read`.
- **Cross-process ping-pong.** Excluded by mechanism: the write source
  fires on kernel-reported writability with no traffic at all, and
  `PipeSignal.signal()` with no waiter only sets a flag — it performs no
  I/O that could wake the peer.[^18]
- **`EV_EOF` spin (dead reader) instead of plain writability.** Not
  distinguishable from the stack alone — a write source on a FIFO whose
  reader vanished also fires continuously.[^1] The plan's fix gates both.
  The distinction only matters for interpretation ("idle but healthy" vs.
  "peer gone"); the plan's manual verification step (idle round-trip still
  works) settles it.
- **`StdioTransport.readLoop()` `Task._sleep`.** A parked sleep burns no
  CPU; ~4 samples is noise. The plan's out-of-scope call is right.

What I could not verify: the `sample` captures themselves (pids, queue IDs,
187%/181% figures) are not in the repo, so the Evidence section's numbers
rest on the plan author's captures. One small precision issue in the plan's
arithmetic claim "Two open write pipes per process": that is true **by
construction** for the CLI, which always holds two `ChunkedWritePipe`s
(announce + request).[^19] The app holds **one response writer per
connected helper**,[^20] so "two hot queues" in the app sample reflects two
helper response pipes open at capture time, not a fixed property. With N
helpers connected the app would burn ~N cores. This strengthens rather than
weakens the case for the fix, but the plan states the "two per process"
symmetry as if it were structural; for the app it is situational.

---

## Overall assessment

The diagnosis and the fix rest on sound, verifiable facts. All five claim
groups check out against the SDK headers, the Darwin man pages, the
libdispatch implementation, and Apple's guide:

- Write sources are level-triggered on writability; an armed write source
  on an idle FIFO re-fires continuously (Point 1).
- Read sources are quiet on an idle fd, given the keepalive that prevents
  the `EV_EOF` state — which the code already holds (Point 2).
- The three lifecycle rules the fix depends on are all documented and
  implemented as the plan states (Point 3).
- New sources start inactive/suspended; no `resume()` means no events
  (Point 4).
- The sampled stacks are exactly what an always-armed write source produces
  (Point 5).

Two refinements for the implementer, neither of which invalidates the plan:

1. **Inactive vs. suspended.** A never-armed source is *inactive*; its bad
   release crashes with "Release of an inactive object," and the header
   requires activation before disposal. Edit 4's resume-before-cancel
   already covers this — keep it for the never-armed path, not only the
   suspended path.
2. **App-side pipe count.** The app spins one core per connected helper's
   response pipe, not a fixed two. Do not treat "two write pipes per
   process" as an invariant when writing the regression test or reading
   future samples.

[^1]: [kqueue(2) man page, EVFILT_WRITE](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man2/kqueue.2:452-463)
[^2]: [kqueue(2) man page, EV_CLEAR](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man2/kqueue.2:336-340)
[^3]: [libdispatch, `_dispatch_source_type_write` registration](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/event/event.c)
[^4]: [libdispatch, `_dispatch_source_invoke2` re-arm and suspension checks](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/source.c)
[^5]: [Concurrency Programming Guide, Dispatch Sources — reading/writing a descriptor](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html)
[^6]: [SDK dispatch/source.h, DISPATCH_SOURCE_TYPE_WRITE](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/dispatch/source.h:202-208)
[^7]: [ChunkedWritePipe event/cancel handlers, queue label, and the wrong EDGES comment](../Sources/GuessWhoMCPTransport/ChunkedWritePipe.swift:ChunkedWritePipe.open)
[^8]: [kqueue(2) man page, EVFILT_READ incl. fifo EV_EOF paragraph](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man2/kqueue.2:367-425)
[^9]: [CappedLineReadPipe keepalive writer fd and pipe-read queue](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:CappedLineReadPipe.open)
[^10]: [dispatch_object(3) man page, SUSPENSION section](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man3/dispatch_object.3:144-172)
[^11]: [libdispatch, `_dispatch_queue_xref_dispose` crash strings](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/queue.c)
[^12]: [libdispatch, DISPATCH_CLIENT_CRASH macro with "BUG IN CLIENT OF LIBDISPATCH: " prefix](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/internal.h)
[^13]: [SDK dispatch/source.h, dispatch_source_create discussion](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/dispatch/source.h:349-373)
[^14]: [SDK dispatch/object.h, dispatch_resume discussion](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/dispatch/object.h:426-449)
[^15]: [dispatch_source_create(3) man page, creation state and CANCELLATION section](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man3/dispatch_source_create.3:104-109)
[^16]: [SDK dispatch/object.h, dispatch_suspend discussion](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/dispatch/object.h:402-419)
[^17]: [libdispatch, `_dispatch_source_latch_and_call`](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/source.c)
[^18]: [PipeSignal.signal — flag set when no waiter is parked](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:PipeSignal.signal)
[^19]: [RelayConnection — announce + request ChunkedWritePipes](../Sources/GuessWhoMCPTransport/RelayConnection.swift)
[^20]: [MCPPipeHost — one response ChunkedWritePipe per helper](../Sources/GuessWhoMCPTransport/MCPPipeHost.swift)
