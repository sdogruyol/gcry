# `make idle-release` on macos-latest: the read came before the idle collection (2026-11-01)

CI run 41209225316 (`80d23a9d`, `release-0.40.0`; its src is 0.39.0's for
Crystal 1.21) failed once on `test (darwin arm64, gates)`, job
124560517197 (`ci-41209225316-job124560517197.txt`):

```
idle collections 28 of 68
empty chunks left mapped by the last collection 4718592
FAIL: the last collection kept 4718592 bytes of empty chunks mapped — it did not release
```

18 chunks of 256 KiB. The re-run passed (job 124574185470: 35 of 75, 0
kept). Branch `idle-release-040`, from `origin/release-0.40.0`.

## Answer

**The gate's read, not the collector.** The release check reads the counters
a fixed 200 ms after the last burst (four idle times), on the assumption that
the idle collection has run by then. On macos-latest it often has not: the
idle thread's collection began a median 132 ms into that gap (58 ms on a
Linux host), after 200 ms in 86 of 1 014 plain runs, and as late as 377 ms.
When the burst before the gap also ran an ordinary collection, the read finds
that collection's sweep — its warm budget, which an ordinary collection keeps
mapped by design — and fails. Every failure in 4 041 probe runs had exactly
that shape, and in every one the idle collection began after the read, 213–377
ms after the burst, and released everything (re-read: 0 kept, the 512 KiB
dormant retain plus the rest unmapped).

**Not 0.39.** 0.38.0 fails the same way at the same rate, and so does 0.39.0
with its dormant counter recounted at every major as before 0.39
(`Heap.shared_counters_atomic = false`). The transition-kept
`@dormant_chunk_bytes` matched a walk of the DORMANT chunks in every failure.

**Fixed in the gate**: it now waits (up to 10 s) for the last gap's idle
collection to finish, then reads, and reads again if a collection began
across the read. It still requires that an idle collection comes and that it
released every empty chunk it found, and now fails by name when none comes.

**And one real non-release in the collector, found reading the idle loop for
this**, not seen in the probe: an idle stretch that begins while an idle
collection is finishing was never collected. Fixed, regression 93.

## Rate and cause, before (round 1)

Run 41215918316 on `probe/idle-release` (`eec8ccf9`; `probe-r1.yml`), four
macos-latest jobs (Apple M1 (Virtual), macOS 26.6.2, Crystal 1.21.0), 75
minutes each. Each job builds three arms and runs them interleaved, so every
arm meets the same runner:

| arm | tree |
|-----|------|
| `v039` | release 0.39.0, `c0d570c5` |
| `v039rc` | `v039` with `PROBE_RECOUNT=1`: `Heap.shared_counters_atomic = false`, the dormant counter zeroed and recounted by every major sweep as before 0.39 |
| `v038` | release 0.38.0, `9157672e` |

Each tree's `bench/idle_release.cr` is replaced by `harness.cr`: the same run,
plus a collection-event hook that stamps every event of every collection with
the thread it ran on (a malloc'd buffer; the hook allocates nothing), the
three counters and the last sweep's breakdown read with no allocation at the
moment of the check, and on a failure a wait for the last gap's idle
collection, a re-read, the event timeline and every chunk's flags. Two
shapes (`probe_loop.sh`): `plain`, one run at a time as `make idle-release`
runs it, and `load`, three at once on the runner's three cores.

| arm | plain | load |
|-----|-------|------|
| `v038` | 0 / 338 | 6 / 1 005 |
| `v039` | 0 / 338 | 2 / 1 011 |
| `v039rc` | 1 / 338 | 5 / 1 011 |

(`round1/runs.csv`, `round1/summary.txt`.) 14 failures in 4 041 runs, every
one the release check, 1 in 1 014 plain. The CI history agrees with a rate
that low: since the 524 288 fix (2026-10-10) about 156 CI runs ran the darwin
gates, and this is the one idle-release failure among them
(`ci-history.tsv`: every failed darwin gates job since 2026-10-01).

When the last gap's idle collection began, from the event stamps (ms after
the last burst; the gap is 200 ms):

| shape | min | p50 | p90 | p99 | max | began after 200 ms |
|-------|-----|-----|-----|-----|-----|--------------------|
| plain | 51.3 | 131.7 | 197.2 | 231.3 | 261.2 | 86 / 1 014 |
| load | 50.4 | 116.7 | 181.3 | 225.9 | 262.5 | 160 / 3 027 |

(The 14 failures' collections, which began after the read, ran 213–377 ms.)
On the Linux host, 3 runs alone and 24 at six to a core: 50–71 ms.

Every failure (`round1/*.log`):

- the read found the burst's **ordinary** collection: a main-thread
  collection 4–14 ms before the burst ended, `kept` = its `warm` bytes
  exactly, `unmap` 0 (3 670 016 to 6 815 744; CI's 4 718 592 is in the
  range);
- no idle collection had begun by the read (13 of 14) or it began just after
  it (read at 213.0 ms, collection at 213.2);
- waiting for it and reading again: **0 kept** in all 14 — `fully_free` =
  `released` + 524 288 `dormant` (Darwin's 512 KiB retain, two chunks), the
  idle collection beginning 213–377 ms after the burst;
- the DORMANT walk equalled `dormant_chunk_bytes` (`CHUNKS` lines).

A run whose idle collection is late but whose burst ran no ordinary
collection passes anyway: the last major is then the previous gap's idle
collection, which released. Both have to coincide, hence the low rate.

## Why late

The idle thread polls with a `nanosleep` of a quarter of the idle time —
12.5 ms here — and collects at the first poll that comes the idle time after
the first poll to see the burst's last allocation: up to the idle time plus
two poll intervals after the burst, 75 ms when a poll takes 12.5. On
macos-latest a 12.5 ms `nanosleep`, beside a Crystal `sleep` as in the gate,
takes about three times that (`nanosleep_probe.cr`, 2 000 sleeps, at the
start of each round-2 job):

| | p50 | p90 | p99 | max |
|---|---|---|---|---|
| macos-latest alone, four jobs | 36.2–53.5 | 62.0–108.0 | 66.4–114.8 | 124.6–257.5 |
| macos-latest three at once, twelve | 34.4–62.6 | 59.6–109.0 | 64.7–119.3 | 81.9–210.6 |
| Linux host alone | 12.58 | 12.59 | 12.60 | 12.62 |

With polls 35–60 ms apart the collection can land as late as 120–170 ms
after the burst, and one poll past 100 ms takes it beyond the 200 ms gap.
Nothing is wrong with the release; it is late. At the default of two
minutes the poll is clamped to a second and the same slack is noise, so the
idle thread's sleep is left as it is.

## The gate (fixed)

`bench/idle_release.cr` keeps the 200 ms last gap, then waits for
`idle_collections` to pass its value at the start of the gap with no
collection in flight, polling every 1 ms for at most 10 s (200 idle times),
and reads. The wait allocates nothing, so the read still comes before the
`GC.disable` arm's allocations (the 524 288 false positive of run
38034037360). If a collection begins across the read — `collecting?` or
`collections` moved — it reads again: a sweep in flight zeroes the three sums
and refills them chunk by chunk, and with the collector fix below the idle
thread runs one more collection when the one it ran overlapped the burst's
last allocations. It prints when the last gap's collection was read, and
fails as "no idle collection in the 10 s after the last burst" if none came,
before the release check. The red arm (`GCRY_IDLE_RELEASE_MS=0`) does not
wait: the collector is not armed, and it fails as before.

What it proves is unchanged: idle collections happen, the stretch after the
last burst gets one, and that collection left `fully_free - released -
dormant == 0`. Only the assumption about when is gone.

## The collector: an idle stretch begun inside an idle collection

`IdleRelease.loop_forever` decides to collect when the activity count
(`Heap#allocation_activity`) has not moved for the idle time, collects, and
then took the count **again** as its baseline: "the collection's own
bookkeeping is not the mutator waking up". The collection lets the mutator go
before it returns (the world restarts, the lazy sweep's
`@block_other_heap` drops), and an allocation in that window — the last of a
burst the collection had interrupted — went into the baseline. The stretch
it began then looked like the one already collected (`collected = true`, no
change), and got no idle collection until the program next allocated: its
warm budget and unswept garbage, kept for good.

`make idle-release` makes such overlaps on purpose (gaps of 1–2 idle
times). The probe did not see this one — all 14 re-reads found the late
collection — and it needs the idle thread to lose the CPU for the rest of a
burst at that point.

Forced by `process_spec/regression/93_idle_stretch_inside_collection_spec.cr`:
a collection-event hook holds the idle thread at its collection's `End`
until the main thread has made its last allocation, then the main thread
sleeps twenty idle times. Before, 1 idle collection (the held one): the
stretch is never collected. Fixed: 2, the held one and exactly one for the
stretch — re-armed by the allocation and not by the collection, which
allocates nothing (an idle collection on the Linux host left the count
unchanged; `total_bytes` only grows, and crediting a cursor set moves bytes
between the two terms of the sum). The control arm
(`IdleRelease.baseline_after_collect = true`, the code before) loses the
stretch on the same construction. Each arm a process of its own.

The fix: the baseline stays the count the decision was made on.

## Rate after (rounds 2 and 3)

Round 2, run 41224476205 (`probe/idle-release` `8af8d09d`; `probe-r2.yml`,
`probe_loop2.sh`): the shipped `bench/idle_release.cr` (no probe harness),
four macos-latest jobs of 75 minutes, two arms interleaved:

| arm | tree | plain | load |
|-----|------|-------|------|
| `fix` | `idle-release-040` `8db51d3d`: both fixes | 0 / 507 | 0 / 1 518 |
| `gateonly` | `release-0.40.0` `16d7112d` with only the fixed gate | 0 / 506 | 0 / 1 512 |

4 043 runs, none failed (`round2/runs.csv`, `round2/summary.txt`). These
runners were slower to wake than round 1's (the table above is theirs): the
gate's read, which now waits for the collection, came a median 287 ms after
the burst on `fix` plain (279–298 across arms and shapes), more than 205 ms
after it in 4 026 of 4 043 runs — the wait's own 1 ms sleeps run long there
too, so that is when the read was made, not when the collection ran.

Rounds 1 and 2 ran on different runner sessions. A round 3 putting the old
gate beside the fixed one on the same runners (run 41232321089,
`probe/idle-release` `b80cdc59`) was cancelled before it finished, so the
before and after rates are not paired: 14 / 4 041 (1 / 1 014 alone) before,
0 / 4 043 (0 / 1 013 alone) after, on runners that woke the idle thread
later in round 2.

## Checks

Linux host, on the branch: `make lint` (ameba 1.7 pinned, fresh install),
`make windows-typecheck`, `make darwin-typecheck`, regression 93 and the gate
cross-compiled for `x86_64-windows-msvc` and `aarch64-apple-darwin`,
`crystal spec -Dgc_none process_spec` (322 examples, 0 failures, the two
macOS-only examples pending), regression 93 also with `-Dgcry_block_headers`
and with `GCRY_BITMAP_ALLOC=0` on top, and five more times by itself; `make
idle-release` green arm PASS, red arm FAIL as required.

## Files

- `harness.cr` — round 1's instrumented `bench/idle_release.cr`.
- `probe_loop.sh`, `probe-r1.yml` — round 1's loop and workflow (they ran
  from `bench/log/macos/idle-release-flake/` on the probe branch).
- `probe_loop2.sh`, `probe-r2.yml`, `nanosleep_probe.cr` — round 2.
- `analyze.py` — round 1's summary from `runs.csv`.
- `round1/`, `round2/` — every run's row and every failure's log.
- `ci-history.tsv`, `ci-41209225316-job124560517197.txt` — the CI side.
