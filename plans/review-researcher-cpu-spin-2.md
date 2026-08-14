# Researcher review, cycle 2 — MCP write-source CPU spin plan (revised)

**Reviewer:** researcher `agent-362cdbee` · **Date:** 2026-08-13
**Plan under review:** [`mcp-write-source-cpu-spin.md`](mcp-write-source-cpu-spin.md) (the REVISED plan)
**Cycle-1 verification:** [`review-researcher-cpu-spin.md`](review-researcher-cpu-spin.md)
**Scope:** Fact-check the claims that the revision added or made sharper. No
source files were changed. This review commits one file only.

Sources used: the SDK dispatch headers and the Darwin man pages on this
machine (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`), the
libdispatch implementation (swift-corelibs-libdispatch, `main` branch), and
the xnu kernel implementation (apple-oss-distributions/xnu, `main` branch).
Note on the kernel citations: the `main` branch of xnu can be newer than the
kernel that ships with this OS. Where that matters, the man page is the
documented contract and I say so.

---

## Point 1 — A new source is INACTIVE; `resume()` on an inactive source acts as `activate()`

**Verdict: CONFIRMED.**

The SDK header states both halves directly. Creation state: "Dispatch
sources are created in an inactive state. After creating the source and
setting any desired attributes ... a call must be made to
dispatch_activate() in order to begin event delivery."[^1] The resume
equivalence: "For backward compatibility reasons, dispatch_resume() on an
inactive, and not otherwise suspended source has the same effect as calling
dispatch_activate()."[^1] The same equivalence appears in the
`dispatch_resume` discussion in `object.h`.[^2] The older man page says the
same thing with the older word: "Newly created sources are created in a
suspended state ... the source must be activated by a call to
dispatch_resume before any events will be delivered."[^3]

One precision to keep in mind for the implementation: the header text says
"inactive, **and not otherwise suspended**." The equivalence holds for the
plan's never-armed path because that path never calls `suspend()` — the
source is inactive and has a zero suspension count. If code ever suspended
an inactive source, one `resume()` would consume the suspension count, not
activate it. The plan's `isSourceArmed` guard keeps the count at 0 or 1 and
never suspends an unactivated source, so the equivalence applies as the
plan uses it.

## Point 2 — Two distinct bad-release crash strings; the inactive one applies to the never-armed path

**Verdict: CONFIRMED.**

Both strings exist in libdispatch, in one function, and the inactive check
runs first:

```c
// _dispatch_queue_xref_dispose (libdispatch src/queue.c)
if (unlikely(_dq_state_is_suspended(dq_state))) {
    ...
    if (unlikely(_dq_state_is_inactive(dq_state))) {
        DISPATCH_CLIENT_CRASH(state, "Release of an inactive object");
    }
    DISPATCH_CLIENT_CRASH(dq_state, "Release of a suspended object");
}
```

[^4]

So a source that was never activated crashes with "Release of an inactive
object," and a source that was activated and then left net-suspended
crashes with "Release of a suspended object" — exactly the split the plan
states in Edit A4. Two supporting facts: (a) this dispose path runs for
sources, because `_dispatch_xref_dispose` routes every object in the queue
cluster (sources included) through `_dispatch_queue_xref_dispose`;[^5]
(b) `DISPATCH_CLIENT_CRASH` prefixes the message with
`"BUG IN CLIENT OF LIBDISPATCH: "`, which yields the full crash strings the
plan quotes.[^6] The documented rule behind the crash: "The result of
releasing all references to a dispatch object while in an inactive or
suspended state is undefined,"[^7] and "Releasing the last reference count
on an inactive object is undefined."[^8] The header adds the source-specific
form: "A source must have been activated before being disposed."[^1]

## Point 3 — A write source with a dead reader reports EV_EOF and still fires continuously

**Verdict: CONFIRMED** (the operative claim; one flag-delivery nuance noted).

The documented contract: `EVFILT_WRITE` "returns whenever it is possible to
write to the descriptor. ... The filter will set EV_EOF when the reader
disconnects, and for the fifo case, this may be cleared by use of
EV_CLEAR."[^9] Two consequences follow. First, EV_EOF on reader disconnect
is documented behavior. Second, the EOF state is persistent unless the
caller opts into `EV_CLEAR` — and libdispatch registers write sources with
`EV_UDATA_SPECIFIC|EV_DISPATCH|EV_VANISHED` and **no** `EV_CLEAR`,[^10] so
after each delivery the invoke path re-arms the note[^11] and the
still-true EOF condition fires again at once.

The kernel implementation confirms the always-ready EOF state. When the
last reader of a FIFO closes, `fifo_close_internal` calls
`socantsendmore()` on the FIFO's write socket.[^12] The socket write filter
then reports ready unconditionally, with EV_EOF set, without any check of
buffer space:

```c
// filt_sowrite_common (xnu bsd/kern/uipc_socket.c)
if (so->so_state & SS_CANTSENDMORE) {
    kn->kn_flags |= EV_EOF;
    kn->kn_fflags = so->so_error;
    ret = 1;
    goto out;
}
```

[^13]

One nuance from reading current xnu `main`: a knote on a FIFO opened
through `open(2)` (a vnode fd — the transport's case) attaches through
`vn_kqfilter` as a vnode-filter knote,[^14] and that filter's write case
activates on nonzero free space and sets EV_EOF itself only on vnode
revoke.[^15] On that code path the dead-reader source still fires
continuously — the free-space condition stays true — but the EV_EOF flag
delivery is the part I could not pin in the `main`-branch vnode path. The
man page remains the documented interface, and the plan does not depend on
the flag: the plan's inference is that the spin continues in the
dead-reader state and the gate must cover it, which holds on every path,
and the plan's manual idle round-trip check is what distinguishes
"idle-but-healthy" from "reader gone." So the plan's use of this claim is
correct.

## Point 4 — The write low-water mark is effectively 1 byte; an idle empty FIFO is always writable

**Verdict: CONFIRMED** (effective behavior and conclusion), **with a
mechanism correction to my cycle-1 footnote.**

libdispatch really does request a 1-byte low-water mark — the write source
type sets `NOTE_LOWAT` with `.dst_data = 1`:

```c
// _dispatch_source_type_write (libdispatch src/event/event.c)
.dst_filter     = EVFILT_WRITE,
.dst_flags      = EV_UDATA_SPECIFIC|EV_DISPATCH|EV_VANISHED,
#if HAVE_DECL_NOTE_LOWAT
.dst_fflags     = NOTE_LOWAT,
#endif
.dst_data       = 1,
```

[^10]

The correction is about what the kernel does with that request. For the
transport's fd (a FIFO vnode), the write knote is evaluated by the vnode
filter, which **ignores the low-water request entirely** and activates on
any nonzero free space: `data = vnode_writable_space_count(vp);
activate = (data != 0);`[^15] where the space count for a FIFO is
`fifo_freespace()` = `sbspace()` of the read socket's receive buffer.[^16]
"Fires on any nonzero free space" is exactly a 1-byte effective threshold,
so the plan's sentence ("The write low-water mark is 1 byte, so an idle
FIFO with an empty buffer is always writable") is correct as a statement of
effective behavior. My cycle-1 footnote implied the kernel honors the
requested `NOTE_LOWAT` of 1; on the socket-filter path the kernel would in
fact clamp a 1-byte request UP to the send buffer's default low-water mark
(`NOTE_LOWAT` can only raise it there),[^13][^9] and on the FIFO-vnode path
it ignores the request. Neither detail changes the conclusion: an idle
FIFO's buffer is empty, its free space is the full buffer, and every
candidate threshold (1 byte, PIPE_BUF, or the socket default) is met. The
idle-spin argument stands on every path.

## Point 5 — The keepalive `O_WRONLY` fd prevents the read-side EV_EOF state; an idle read source does not fire

**Verdict: CONFIRMED.**

The read filter for FIFOs "[r]eturns when there is data to read," and:
"When the last writer disconnects, the filter will set EV_EOF in
flags."[^17] The kernel mechanism matches the man page exactly:
`fifo_close_internal` decrements the writer count and calls
`socantrcvmore()` on the read socket **only when the count reaches
zero**.[^12] `CappedLineReadPipe.open()` holds a keepalive `O_WRONLY` fd on
its own FIFO,[^18] so the writer count never reaches zero, `socantrcvmore`
never runs, and the persistent EOF state never arises. With no EOF state
and no data, the filter has nothing to report — the vnode read filter
activates only when the readable byte count is nonzero[^15][^19] — so an
idle armed read source costs nothing. The plan's instruction to leave the
read source armed, scoped by the keepalive + single-consumer contract, is
sound.

## Point 6 — Does the one-shot pipe contract conflict with any documented dispatch rule?

**Verdict: CONFIRMED — no conflict.**

I checked the dispatch documentation for any rule the one-shot design
could contradict. There is none; the design is more conservative than GCD
requires:

- Cancellation is one-way: `dispatch_source_cancel` "asynchronously cancels
  the dispatch source, preventing any further invocation of its event
  handler block," and the cancellation handler runs "only once."[^20] GCD
  offers no way to reuse a cancelled source; new monitoring means a new
  source. The one-shot contract removes even the *creation* of a second
  source on the same instance, which is strictly inside the documented
  model.
- The fd rule is honored: "a cancellation handler is required for file
  descriptor ... based sources in order to safely close the descriptor,"
  because closing the fd before the cancel handler runs can race a handler
  still using the descriptor number.[^21] The plan keeps the fd close in
  the cancel handler and never reuses the instance, so no new source can
  ever observe a stale fd.
- The activation and release rules (Points 1 and 2) are per-source and are
  satisfied by resume-before-cancel regardless of the one-shot choice.

The one-shot contract is a design decision at the `ChunkedWritePipe` layer,
and every production caller already constructs a fresh pipe per
connection,[^22][^23] with `closePipes()` closing and nil-ing the old
ones.[^24] Nothing in dispatch pushes back on it.

---

## Re-check: did the revision weaken or misstate any cycle-1 claim?

**No. The revision incorporated both cycle-1 refinements correctly and
weakened nothing.**

- **Inactive vs. suspended.** Cycle 1 flagged that the plan understated the
  two sub-states. The revision now states both crash strings, maps them to
  the never-armed and armed-then-disarmed paths, and notes that `resume()`
  activates an inactive source — all consistent with the sources verified
  above (Points 1 and 2). This is a strengthening.
- **App-side pipe count.** Cycle 1 corrected "two write pipes per process"
  to: CLI = two by construction, app = one response writer per connected
  helper. The revision's Evidence section now says exactly that, and the
  construction sites still match the code.[^22][^23]
- **Level-trigger mechanics.** The revision's root-cause text (level
  filter, `EV_DISPATCH` without `EV_CLEAR`, invoke-path re-arm) matches
  what I re-verified directly: the registration flags[^10] and the re-arm
  in `_dispatch_source_invoke2`, including its "do not try to rearm the
  kevent if the source is suspended" branch[^11] — which is the exact
  mechanism that makes the plan's suspend-gate stop the spin.
- **Read-source scoping.** The revision keeps cycle 1's condition (single
  consumer + keepalive) rather than claiming unconditional safety. Correct
  per Point 5.
- **Suspension defers the cancel handler.** Restated unchanged from cycle 1
  and re-verified: "suspension applies to all aspects of the dispatch
  object life cycle, including the finalizer function and the cancellation
  handler."[^7]
- **No-lost-wakeup note.** The revision's claim that a source armed after a
  missed writability edge still fires is supported by attach-time filter
  evaluation: `vn_kqfilter` runs the filter once at attach and activates
  the knote immediately if the condition already holds.[^14]

The only cycle-1 statement that needed repair is mine, not the plan's: the
footnote attributing the 1-byte threshold to the kernel honoring
`NOTE_LOWAT` (Point 4 above). The plan's sentence built on it remains
correct as effective behavior.

## Limitation

One mechanism sits outside the six claims and outside what I could fully
trace in xnu `main`: the kernel plumbing that re-activates a FIFO vnode
write knote when a **full** pipe drains (the wake after a real `EAGAIN`
park). The current transport demonstrably receives these wakeups, and the
plan's Test 2 (park on `EAGAIN`, drain in small increments, assert
byte-for-byte delivery) is precisely the empirical guard for that path
under the new gate. I recommend keeping Test 2 exactly as specified — it
covers the one piece of kernel behavior this review takes on evidence
rather than on a source citation.

## Overall assessment

All six claims check out; two carry nuances that do not change the plan:

1. New sources are inactive; `resume()` activates a never-suspended
   inactive source — CONFIRMED (Point 1).
2. Both crash strings exist, inactive is checked first, and the inactive
   one is the never-armed path's crash — CONFIRMED (Point 2).
3. Dead-reader write sources keep firing; EV_EOF is the documented flag —
   CONFIRMED for everything the plan infers; the flag delivery on the
   current vnode path is the one unpinned detail (Point 3).
4. Effectively 1-byte write threshold; idle empty FIFO always writable —
   CONFIRMED, with the mechanism attribution corrected (Point 4).
5. The keepalive prevents the read-side EOF state; an idle read source is
   silent — CONFIRMED at both the man-page and kernel level (Point 5).
6. One-shot conflicts with no dispatch rule and is more conservative than
   GCD requires — CONFIRMED (Point 6).

The revision is factually sound, incorporates both cycle-1 refinements
faithfully, and weakens nothing. From the facts side, the plan is ready to
implement.

[^1]: [SDK dispatch/source.h, dispatch_source_create discussion](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/dispatch/source.h:356-373)
[^2]: [SDK dispatch/object.h, dispatch_resume discussion](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/dispatch/object.h:426-449)
[^3]: [dispatch_source_create(3) man page, creation state](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man3/dispatch_source_create.3:104-109)
[^4]: [libdispatch src/queue.c, `_dispatch_queue_xref_dispose`](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/queue.c)
[^5]: [libdispatch src/object.c, `_dispatch_xref_dispose` — queue-cluster dispose covers sources](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/object.c)
[^6]: [libdispatch src/internal.h, `DISPATCH_CLIENT_CRASH` macro](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/internal.h)
[^7]: [dispatch_object(3) man page, SUSPENSION section](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man3/dispatch_object.3:144-172)
[^8]: [SDK dispatch/object.h, dispatch_activate discussion](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/dispatch/object.h:375-395)
[^9]: [kqueue(2) man page, EVFILT_WRITE](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man2/kqueue.2:452-463)
[^10]: [libdispatch src/event/event.c, `_dispatch_source_type_write` — NOTE_LOWAT, dst_data 1, no EV_CLEAR](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/event/event.c)
[^11]: [libdispatch src/source.c, `_dispatch_source_invoke2` — re-arm via `_dispatch_unote_resume`, skipped while suspended](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/source.c)
[^12]: [xnu bsd/miscfs/fifofs/fifo_vnops.c, `fifo_close_internal` — reader count 0 → socantsendmore; writer count 0 → socantrcvmore](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/miscfs/fifofs/fifo_vnops.c)
[^13]: [xnu bsd/kern/uipc_socket.c, `filt_sowrite_common` — SS_CANTSENDMORE ⇒ EV_EOF + ready; NOTE_LOWAT can only raise the socket low-water mark](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_socket.c)
[^14]: [xnu bsd/vfs/vfs_vnops.c, `vn_kqfilter` — FIFO read/write knotes attach as vnode-filter knotes and are evaluated once at attach](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_vnops.c)
[^15]: [xnu bsd/vfs/vfs_vnops.c, `filt_vnode_common` — write activates on data != 0; EV_EOF set only on NOTE_REVOKE](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_vnops.c)
[^16]: [xnu bsd/miscfs/fifofs/fifo_vnops.c, `fifo_freespace` — sbspace of the read socket's receive buffer](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/miscfs/fifofs/fifo_vnops.c)
[^17]: [kqueue(2) man page, EVFILT_READ, Fifos/Pipes paragraph](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man2/kqueue.2:367-425)
[^18]: [CappedLineReadPipe keepalive O_WRONLY fd](../Sources/GuessWhoMCPTransport/CappedLineReadPipe.swift:CappedLineReadPipe.open)
[^19]: [xnu bsd/miscfs/fifofs/fifo_vnops.c, `fifo_charcount` — FIONREAD on the read socket](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/miscfs/fifofs/fifo_vnops.c)
[^20]: [dispatch_source_create(3) man page, CANCELLATION section](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man3/dispatch_source_create.3:264-289)
[^21]: [dispatch_source_create(3) man page, fd cancellation-handler requirement](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man3/dispatch_source_create.3:289-296)
[^22]: [RelayConnection.connect — fresh announce + request ChunkedWritePipes per connect](../Sources/GuessWhoMCPTransport/RelayConnection.swift:RelayConnection.connect)
[^23]: [MCPPipeHost — fresh response ChunkedWritePipe per helper session](../Sources/GuessWhoMCPTransport/MCPPipeHost.swift)
[^24]: [RelayConnection.closePipes — closes and nils the pipes](../Sources/GuessWhoMCPTransport/RelayConnection.swift:RelayConnection.closePipes)
