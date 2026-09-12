# The suspend acknowledgement had to leave `Thread#@suspended`

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `95a8b2e`
`make stw-ack-window`, three arms, one red on purpose. Found while reading
Crystal's `Thread#start` for the next step of the stop-epoch work
(`../2026-09-12-stw-stop-epoch/`).

## The defect

Crystal publishes a thread before it sets that thread's TLS
(`crystal/system/thread.cr:239-241`):

```crystal
protected def start
  Thread.threads.push(self)   # on the list — `stop_world` signals it
  Thread.current = self       # TLS only now
```

`stop_world` learns about threads from that list, so a thread between those
two lines is **signalled and has no `Thread.current`**. gcry's suspend handler
asked for one anyway, and Crystal's accessor creates on a miss
(`crystal/system/unix/pthread.cr:68-76`):

```crystal
def self.current_thread : ::Thread
  if ptr = LibC.pthread_getspecific(@@current_key)
    ptr.as(::Thread)
  else
    self.current_thread = ::Thread.new
  end
end
```

The no-argument `Thread` constructor (`thread.cr:152-158`) allocates a
`Fiber`, allocates a `Thread`, and pushes it onto `Thread.threads` — taking
the list mutex the collector holds for the length of a stop. So from inside a
signal handler, with the world stopping:

1. an **allocation**, which is not async-signal-safe and reenters the
   collector's own allocator;
2. a **second `Thread` object** for one OS thread;
3. `@suspended = true` set on that second object — **not** the one on the
   list, which is the one `stop_world` is watching.

The collector therefore spins for a thread that has already suspended itself.
That is `phase=suspend`, one thread unacknowledged, `pthread_kill(id, 0)`
answering that the handle is live, and handler entries incremented — the
shape of the six aarch64 job timeouts.

## The fix

The acknowledgement moves into the `pthread_t`-keyed slot table the stop
epoch already established, and the collector **reserves every thread's slot
before it signals anyone**. The handler then writes one plain bool and calls
nothing Crystal owns. `Thread.current?` — the accessor that does *not*
create — is consulted only to count the window.

Reserving up front pays twice: the handler never runs the CAS claim loop (the
one place that cannot afford to contend), and the collector's wait spins on an
array index instead of scanning 64 slots per iteration.

Order of preference for where an acknowledgement goes:

| route | when | why |
|---|---|---|
| reserved slot | always, on the shipped path | no Crystal at all |
| `Thread#@suspended` | table full **and** the thread has TLS | it is what the pre-table path did |
| nowhere — decline to suspend | table full and no TLS | a thread frozen with no way to say so is a stop that never ends; the collector reports, resends, and can abandon |

`stw_suspend_no_tls` and `stw_suspend_ack_unavailable` are on `/gc-stats`.

## Result — `make stw-ack-window`

The window is one store wide, so waiting for a real birth to land in it is not
a test. A **raw pthread** — created with `LibC.pthread_create`, spinning on a
plain word, never touching the runtime — has no TLS by construction and
permanently. Signal it exactly as a stop does: list mutex held, slot
reserved, epoch open.

| arm | acked | threads added to Crystal's list by the handler |
|---|---|---|
| shipped (slot table) | **true** | **0** |
| `GCRY_STW_ACK_VIA_THREAD=1` (pre-table) | **false** | **1** |

`listed_delta=1` is the allocation, measured: the handler created a `Thread`
and pushed it onto `Thread.threads` from inside a signal handler. `acked=false`
is the consequence: the acknowledgement went to an object the collector is not
watching.

Third arm, the realistic one: 300 rounds × 6 real thread births against a
collecting heap, 1800 threads, 615 handler entries — `no_tls=0`. **Reported,
not asserted.** A quiet x86_64 box missing a one-store window says nothing
about a loaded aarch64 runner, which is why the counter ships rather than the
zero.

## Two harness errors worth recording

Both produced a convincing red arm that was wrong, and both were caught by
asking what the number meant rather than accepting it.

1. **The collector read the slot while the control arm's handler wrote the
   `Thread` flag.** `via-thread` hung 3 of 3 with a `/proc` picture — main
   spinning, mutators in `rt_sigsuspend` — that read exactly like the defect.
   It was the reader and the writer disagreeing. Fixed by making one function
   choose the side for both (`suspend_ack_slot`).
2. **The first version of this gate expected a deadlock** on `Thread.lock`.
   It does not deadlock: the handler's push goes through and the process
   continues. The real mechanism is the second `Thread` object, which is
   worse — a hang with no lock contention to find.

## Gates run on this tree

`stw-ack-window`, `stw-epoch`, `stw-watchdog`, `stw-monitor-gate`,
`greg-roots`, `find-block-race`, `stw-index-race`,
`stw-mt-property-test-short`, `spec` (277), `spec-process` (32), `lint` (150),
`knob-doc-check` (171), cross-compile to aarch64-gnu, aarch64-darwin,
x86_64-msvc and x86_64-musl.

## What this does and does not close

It closes the acknowledgement half: a thread with no Crystal TLS can now
answer a suspend, and the handler allocates nothing. Whether it explains any
of the six aarch64 timeouts is **unknown** — `no_tls` is the counter that will
say, and it has never been measured on that runner.

It does **not** close the birth window itself (`ROADMAP.md`, "The second
use-after-free"). An unpublished thread — one that has not reached
`Thread.threads.push` yet — is still neither suspended nor scanned, because
`stop_world` cannot see it. What remains for that: take the staged thread's
stack bounds from the creating side (`pthread_getattr_np` on the new handle
after `pthread_create` returns), reserve it a slot, and signal it like any
other. The handler is now capable of serving it; nothing else is.
