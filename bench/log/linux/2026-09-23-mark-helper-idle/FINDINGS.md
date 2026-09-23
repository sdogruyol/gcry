# Parallel-mark helpers burned a full core each, for the life of the process

**Date:** 2026-09-23 · host: Linux 7.0.0-31-generic x86_64 (QEMU), 12 vCPUs, Crystal 1.21.0

`tasks/todo.md` carried "helpers still busy-spin between collections
(separate, pre-existing)" with no number. The number:

An idle process — one collection to start the helpers, then a mutator
that sleeps for 2 s — CPU time over those 2 s:

| `GCRY_PARALLEL_MARK` | before | after |
|---|---|---|
| 1 | 0.4% of a core | 0.4% |
| 2 | **100.7%** | 4.3% |
| 4 | **301.3%** | 11.9% |
| 8 | **702.9%** | 26.9% |

Every helper spun on `@mark_epoch` with `Intrinsics.pause` for as long as
the program ran. On a 4-core host `GCRY_PARALLEL_MARK=4` would take three
of them from the mutator whether or not a collection was running — part
of why that knob "regresses HTTP throughput".

## The change

`MARK_IDLE_SPINS` (20 000) polls without a syscall — long enough for the
back-to-back epoch bumps inside one collection — then sleeps of
`MARK_IDLE_SLEEP_NS` (200 µs). A helper joins a collection that starts
after an idle stretch at most one sleep late; the master starts marking
alone and the late helper takes from the shared stack, so lateness costs
parallelism, never correctness. Polling rather than a condition
variable: there is no lost wake-up to reason about, and on Windows this
layer's mutex is an SRWLOCK with no condvar in the shim.

## The cost, measured where parallel mark pays

512-byte objects (`gc_phases --fanout=6 --shuffle --size=64`), where 2
and 4 workers beat one; n=6 per arm, interleaved, old spin vs backoff:

| | spin | backoff | Δ | t |
|---|---|---|---|---|
| 2w `pause_per_gc_us` | 16 382 | 16 488 | +0.65% | +0.81 |
| 4w `pause_per_gc_us` | 11 583 | 11 391 | −1.65% | −1.45 |
| 2w `ns_per_alloc` | 207.5 | 208.9 | +0.67% | +0.83 |
| 4w `ns_per_alloc` | 161.4 | 159.6 | −1.12% | −1.31 |

No measurable cost. The residual ~4% of a core per helper is 5 000
wake-ups a second; a longer sleep would trade it for later joins, and
that trade has no measurement behind it yet.
