# Idle RSS: unmap grace was unbounded (2026-09-23)

Host: QEMU x86_64, 12 vCPU, Crystal 1.21.0, headerless default, `-Dgc_none`.
Load generator: `wrk` 4.1.0 from the distro `.deb`, unpacked user-local — this
host has no `wrk` on `PATH`, and a first pass of the Kemal numbers below ran
with none: the script sent wrk's error to `/dev/null` and "after load" meant
"after nothing" (`majors=0` was the tell). Those numbers are discarded.

## The item as filed

`tasks/todo.md`: "post-GC RSS is 27 MB (Boehm 26, master 15) because warm
chunks stay resident; a time-decay release from the monitor thread would lower
idle RSS". Two different things turned out to hold chunks at idle.

## 1. Unmap grace, after a burst — fixed

An emptied bitmap chunk past the warm budget is kept mapped for one cycle and
unmapped at the next major unless a cursor takes it (added against a Kemal
remap churn, `collect_sweep.cr`). The grace had no bound, and an idle process
has no next major.

`bin/probe_burst` (throwaway): build 200 MB of 64 B nodes, drop them, allocate
garbage until two automatic majors have run, idle, then `GC.collect`.

| arm | idle RSS | after `GC.collect` | small mapped at idle |
|---|---|---|---|
| uncapped (`GCRY_UNMAP_GRACE_UNBOUNDED=1`) | **78.7 MB** | 7.0 MB | 77.9 MB |
| capped at one threshold | **22.4 MB** | 6.6 MB | 19.0 MB |
| 50 MB burst, uncapped / capped | 45.9 / 22.4 MB | 6.4 / 6.0 MB | |

Why a cap at the threshold costs nothing: a cycle allocates about one threshold
before the next major, so it cannot take more than that from the graced
chunks; the rest were always going to be unmapped at the next major.

Why two majors: the first major after the drop keeps the *old* threshold's
worth warm (64 MiB) and graces the rest; the second, at the adapted 8 MiB,
unmaps what the first graced but finds the 64 MiB of warm chunks past the new
budget and graces them; a third unmaps them. So the leak is one idle window —
after the second major — and a gate that waited for a third passed both arms.
Still open by the same reasoning: idle right after the *first* major keeps up
to warm + grace at the old threshold (at most 2 x 64 MiB at the clamp).

Steady state is untouched — Kemal `/json`, 10 s x 50 connections, interleaved,
n=10 per arm, one binary:

| | capped | uncapped | delta | t |
|---|---|---|---|---|
| req/s | 44 138 | 44 002 | +0.31% | +0.43 |
| RSS after load | 20 909 kB | 20 898 kB | +0.05% | +0.11 |
| `empty_chunk_grace_kept` | 0 | 0 | | |
| `unmapped_bytes` | 0 | 0 | | |
| `chunks_mapped` | 149 | 149 | | |

Grace never engages in this steady state, so the cap cannot act on it.

Gate: `make idle-rss-after-burst` (`bench/idle_rss_after_burst.cr`) — the empty
chunks the last sweep left mapped (`fully_free - released - dormant`) must fit
`warm + threshold`; shipped 16 777 216 = bound, uncapped 75.4 MB, 58.6 MB over.
Exact by construction, so no margin to tune. An earlier bound on the whole
small mapping passed by one chunk in an unoptimised build, and before that
the burst stayed live in one (a debug frame slot held the list head).

## 2. The warm budget, at steady-state idle — still open

Kemal `/json` under load, then idle (n=2 each):

| | after load | idle 60 s | after `/gc-collect` |
|---|---|---|---|
| gcry | 21.1 MB | 19.9 MB | 13.3 MB |
| Boehm | 14.5 MB | 13.4 MB | 13.4 MB |

gcry idles 6.6 MB above its own floor and ~1.5x Boehm's idle: that is the warm
budget (`fully_free_chunk_bytes` 7.6 MB, warm retain 8 MiB), kept on purpose so
the next cycle does not fault its chunks back in. Releasing it when idle needs
a clock — nothing in gcry runs without an allocation to drive it — and that is
the design the todo item names. Not done here.
