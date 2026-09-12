# The stop epoch: making an unanswered suspend signal re-sendable

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `9d82c2c`
`make stw-epoch`, six arms, three red on purpose. Everything below is from
this box; the defect it is aimed at has only ever been seen on aarch64 CI.

## Question

`stop_world` spins `until thread.@suspended.get`. Six of forty runs of
`test (aarch64 native)` ended at the 20-minute job timeout in that loop —
2026-08-20 (three) and 2026-08-22 — and a job timeout reports as *cancelled*
rather than failed, so none of them was read as a defect. The watchdog later
named the region (`STOP-THE-WORLD STALLED 10009 ms in phase=suspend`,
run `32575506486`).

The repair is the one `start_world` already makes for resume: send the signal
again. The roadmap had it written down and refused, twice, for a stated
reason:

> A redundant `SIG_RESUME` runs an empty handler; a redundant `SIG_SUSPEND`
> stays pending while the thread is inside its own handler and is delivered
> *after* it resumes, suspending it again with nobody waiting. Doing it
> properly needs a per-thread stop epoch so the handler can ignore a signal
> it has already served.

So: build the epoch, then the resend, and show both halves rather than
arguing them.

## Mechanism

`Gcry::Platform.@@stw_epoch` is 0 when no stop is in progress and carries the
stop's id while one is. `begin_stop_epoch` stamps it before the first
`pthread_kill`; `end_stop_epoch` clears it before the first resume, and on
every path that leaves `stop_world` without a stopped world. A sentinel
rather than a parity bit because `stop_world` has `rescue` exits, and a
counter whose meaning depends on being bumped an even number of times inverts
there — every later signal dropped, which is the same hang with the collector
holding the wrong end.

The handler honours a delivery only when the epoch is non-zero and this thread
has not already served *that* epoch (stamped per slot in the `pthread_t`-keyed
table this file already kept for SP and registers). The three declined cases
are each safe:

| case | what it is | why declining is right |
|---|---|---|
| epoch 0 | no stop in progress | a thread suspending here is never resumed |
| already served | same stop, duplicate | the collector has its acknowledgement |
| newer epoch, unserved | stale signal inside the next stop | it suspends, which that stop wants; the collector's own signal is then the already-served case |

The wait resends every `GCRY_STW_RESEND_SPINS` (20 M, ~a tenth of the stall
report) up to `GCRY_STW_RESEND_LIMIT` (16). Past the limit it asks
`pthread_kill(id, 0)`: on `ESRCH` the handle names no live thread, so there is
nothing to suspend and nothing that can mutate the heap through it — the stop
reports `SUSPEND ABANDONED` and proceeds. Any other answer keeps spinning,
because skipping a **live** thread would stop a world that is still running.

The resend goes out through `pthread_kill` directly, not `Thread#suspend`:
that method clears `@suspended` before signalling, so a thread that had just
acknowledged would have its acknowledgement erased and the collector would
wait forever for one that never comes again.

## Result — `make stw-epoch`, 4 mutator threads, 6 collections per arm

| arm | outcome | counters |
|---|---|---|
| `drop+resend` | completes | resends 6, dropped 6 |
| `drop+no-resend` | **HUNG** (20 s) | — |
| `double+epoch` | completes | stale declines 24 |
| `double+no-epoch` | **HUNG** (20 s) | — |
| `mute+dead` | completes | resends 12, abandoned 6 |
| `mute+live` | **HUNG** (20 s) | — |

`drop` swallows the first suspend signal of every stop — a lost delivery, the
thing the resend exists for. `mute` swallows every signal to a thread,
resends included — a thread that cannot take the signal at all, which no
number of resends repairs. `mute+live` is red deliberately and is the honest
limit of this work: **the resend fixes a lost delivery, not a thread that
cannot run its handler.** It doubles as the control for `mute+dead`; if it
ever goes green the abandonment is firing on live threads, i.e. a collector
that stops without stopping them.

`double+no-epoch` is the arm that matters most. It is the hazard that kept the
resend out twice, reproduced on demand: 24 redundant deliveries, no epoch,
and the next stop waits forever on a thread that suspended itself with the
world running.

## Two defects the epoch found, neither of them new

Both are in the `pthread_t`-keyed slot table (`linux_stw.cr`), both latent for
as long as it has existed, and both surfaced because the epoch turned a
silently-shared slot into a hang.

**1. The claim CAS was never checked.** `Atomic#compare_and_set` returns
`{old_value, success}` — a **tuple**, which is always truthy — so
`if @@stw_claimed.compare_and_set(…)` took the success branch whether or not
the exchange happened. Every thread signalled in one stop reads `claimed`
before any of them writes it, picks the same lowest free bit, and they all
"claim" it.

**2. Releasing a slot did not clear its id.** `clear_thread_sps` cleared the
claimed bitmask, the SPs and the register rows, but left `@@stw_ids`. The
claim publishes its bit by CAS and writes the id *afterwards*, so a peer
scanning for its own handle could match a slot another thread had just
claimed — because that slot still held the scanner's id from the previous
stop.

What they cost before the epoch: two threads sharing one slot means the
loser's stack is scanned from the winner's SP and its registers are the
winner's registers. That is a **missed root**, in the one table the
conservative scan trusts to be per-thread, and nothing would have reported it.
What they cost after: a decline, and a stop that waits forever.

Observed, not reasoned: (1) as four mutator threads on a first collection
leaving three in `rt_sigsuspend` and one spinning (`/proc/<pid>/task`), (2) as
`find_block_race --child alloc` with `GCRY_INDEX_AUDIT=1` hanging with
`declined … redundant 2` in the stall report. Both reproduce 0 of 3 after the
fix, and `find-block-race` is green on all four workloads with both control
arms still crashing.

Whether either explains any open CI sighting is **unknown** and should not be
assumed. They are real, they are fixed, and the missed-root shape is worth
remembering next to the crashes that are still unattributed.

## What the report says now

`SUSPEND STALLED` carries the three numbers that separate the readings of a
missing acknowledgement, which the first sighting could not:

```
gcry: SUSPEND STALLED on thread 0x… — 1 of 4 acknowledged, 1 resends
unanswered; handler entries so far 175, declined stale 0 / redundant 2.
the handle is live (pthread_kill 0 → 0)
```

- handler entries flat across the resends → the delivery is not arriving.
- stale/redundant climbing → it arrives and is declined.
- both flat with a live handle → the thread cannot run its handler, which is
  the one case this change does not repair.

## Gates run on this tree

`stw-epoch`, `stw-watchdog`, `stw-monitor-gate`, `stw-startup-hang`,
`stw-index-race`, `find-block-race`, `stw-mt-property-test-short`,
`scheduler-roots`, `ec-queue-audit`, `greg-roots`, `thread-birth-root`,
`mark-audit`, `thread-storm-short`, `spec` (277), `spec-process` (32),
`lint` (150), `knob-doc-check` (170).

## What is still open

The birth window (`ROADMAP.md`, "The second use-after-free") is **not** closed
by this. An unpublished thread is still neither suspended nor scanned; what
the epoch adds is the mechanism a fix would need — a thread can now be
signalled more than once without hazard, and the handler's admission decision
no longer depends on anything the collector has to get right at the call site.
Suspending a staged thread additionally needs the handler to stop touching
`::Thread.current` (its ack would have to move into this table, keyed by
`pthread_t`) and the thread's stack bounds taken from the creating side. That
is a separate change with its own red arms, and two earlier attempts at this
family broke the collector by doing it in one step.
