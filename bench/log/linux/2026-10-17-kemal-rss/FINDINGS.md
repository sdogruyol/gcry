# Kemal `/json` peak RSS: where gcry's extra memory is, and what came off

Linux x86_64, 12 vCPUs (QEMU guest), Crystal 1.21.0, `--release`, base
`release-0.37.0` at `e8c0327e`. Kemal `/json` (`bench/kemal/src/server.cr`)
on CPUs 0–2, `wrk -t4 -c50` on CPUs 3–11, 3 s warm-up then 10 s measured.
Every measured run held the host-wide lock.

## Method

- `sample.py`: reads `/proc/<pid>/smaps` every 100 ms during the measured
  10 s and groups each mapping's `Rss`. gcry's own mappings are named by a
  probe build (`probe-vma-names.patch`: `prctl(PR_SET_VMA_ANON_NAME)` at
  every `Gcry.os_map` call site — size-class chunks, large chunks, bitmap
  pools, radix, mark stack and batch, parallel-mark shards, OOM reserve,
  ...), Crystal's fiber stacks by `vma_names.cr` (both GCs), thread stacks
  by the SP in `/proc/<pid>/task/*/syscall`. The probe server
  (`server-probe.patch`) adds `/gc-prof` (`GC.prof_stats`, both GCs),
  `/large-census` (every large chunk: mapped, size, resident by `mincore`,
  first word), `/live-attr`, `/sockets-finalized` (a counter in
  `Socket#finalize`, both GCs) and `/tids`. `/gc-stats` once a second.
  Raw: `attr/*.json`; table: `attr_table.py`.
- Per-collection threshold, heap size and pause: `GCRY_TRACE=1`.
- Speed and peak: `kemal_ab.sh` (the 2026-10-14 script, port moved), 9
  trials, arms in random order per trial and path, req/s and `VmHWM`.
- crystal-metric and Kemal on all five GitHub runners: `Perf A/B`
  (run ids below).

## Breakdown, release tip against Boehm

Peak sample (largest total `Rss`), median of two runs each, kB:

| category (peak sample, kB) | Boehm | gcry tip |
|---|---:|---:|
| gcry size-class chunks | – | 10 626 |
| gcry large chunks (resident pages) | – | 1 240 |
| other anonymous (Boehm: its whole heap) | 7 312 | 656 |
| shared libraries | 5 732 | 5 694 |
| executable (text, data) | 2 036 | 2 588 |
| fiber stacks | 1 214 | 1 000 |
| thread stacks | 184 (13 threads) | 88 (4 threads) |
| libc heap | 40 | 108 |
| bitmap pools, radix, mark stack and batch, misc | – | ~200 |
| **total = VmHWM** | **16 632** | **22 254** |
| after `/gc-collect` | 16 632 | 14 302 |
| collections in the run (`gc_no`) | 1 359 | 380 |
| heap size (end) | 11.7 MB | 23.9 MB |

What it says:

1. **The heap is the difference: 11.9 MB against Boehm's 7.3 MB.** The
   size-class chunks peak at the threshold (9.6 MB) plus ~1 MB, since every
   byte a cycle allocates goes to memory not yet reused that cycle.
2. **Kemal's "~10 MB live set" is 0.2 MB of small objects and 9.4 MB of
   32 KiB `IO::Buffered` buffers.** Three per connection (socket read,
   socket write, response output; their first words read `GET `, `HTTP`,
   `{"ok`), allocated `malloc_atomic`, 1.2 MB of their 9.4 MB ever written
   (`mincore`). Counted whole in live × factor, they put the adaptive
   threshold and the warm budget at 9.6 MB, above the 8 MiB floor.
3. **About a hundred of them belong to closed connections, under both
   collectors.** After a `wrk` run and two or three `GC.collect`s, 109–113 large
   buffers are still live with no connection open; gcry's first-mark
   attribution reaches 51 `TCPSocket`s through heap edges. Boehm keeps them
   just as long: `Socket#finalize` ran 0/5/8/59 times (Boehm) against
   2/5/9/57 (gcry) at the same four points (after the first run, three
   collects, the second run, three collects). Not a gcry retention; it sets
   the threshold only because gcry counted the buffers whole.
4. **Boehm collects every ~2.8 MB**: 1 359 collections to gcry's 380, its
   heap 11.7 MB mapped with 7.3 MB resident. bdwgc's `min_bytes_allocd`
   weights its live set as `2 × composite + atomic / 4 + roots`, ÷ 3.
5. **gcry's collections here are cheap.** At the tip (9.6 MB, 29/s) they
   are 0.41% of the wall time, 141 µs each; at a fixed 4 MiB, 67/s, 0.76%,
   114 µs. Single runs at fixed thresholds: 4 MiB → 17.0 MB peak, 6 MiB →
   19.0 MB, the 8 MiB floor (`GCRY_THRESHOLD_FACTOR=10`) → 21.1 MB.
6. **The `Heap` object is 556 KiB and every page of it is resident**
   ("other anonymous", one `calloc`'d 560 KiB mapping from `Heap.new`):
   Crystal's `allocate` clears an instance. 472 KiB of it are the unmap
   guard's record ring, the release quarantine and the release map, used
   only under `GCRY_UNMAP_GUARD`, `GCRY_RELEASE_LEDGER`,
   `GCRY_RELEASE_QUARANTINE`.
7. **Not it:** the parallel mark never ran (`parallel_mark_runs` 0, live
   under the 32 MiB floor) and its shard buffers have no resident page; the
   OOM reserve has none; mark stack and batch 8 KiB each; the idle
   collector's thread is in the 88 KiB of thread stacks; the large cache
   keeps nothing on Linux (`large_cache_retain` 0). gcry's executable is
   0.55 MB larger than Boehm's (its code), not addressed here.

## Fixes

Four commits, in order (two kept on `kemal-rss`, two parked on `kemal-rss-floor`; see Decision):

| commit | change | Kemal effect (Linux, local) |
|---|---|---|
| `fa51f65f` | atomic live bytes count a quarter in live × factor (Boehm's `min_bytes_allocd` weighting) | threshold 9.6 MB → the 8 MiB floor; 29 → 33 collections/s (a run held at the floor, `GCRY_THRESHOLD_FACTOR=10`: 21.1 MB) |
| `5ebcaabf` | the floor comes down to what holds collection time to 2% of the mutator time, 4–8 MiB (`Heap.threshold_floor`) | threshold 4 MiB, 66/s, 0.73% of wall; with commits 1–3 the peak was still 20.7 MB (below) |
| `6776e84a` (`a975d5cd` on `kemal-rss`) | the unmap guard / ledger / quarantine / release-map tables are mapped when armed, not `StaticArray`s in `Heap` | `instance_sizeof(Heap)` 569 784 → 86 552 B; −472 KiB resident in every process |
| `41457821` | the cost floor starts at 4 MiB (until two cycles are measured, and after a releasing collection) and reads the cheaper of the last two cycles | threshold 4 MiB on every collection (790 and 815 of them in two traced runs); peak 16.0–16.5 MB |

Why the fourth: with only the second, a `GCRY_TRACE` run showed what kept the
peak at 20.7 MB. The first majors ran at 8 MiB before anything was measured,
and when the second `wrk` opened 50 connections, ~5 MB of new buffers were
allocated in 2.3 ms: that cycle read a cost of 232 KB against a median of
33 KB (`probes/tracerun.sh`), so the next one ran at 8 MiB. The size-class
chunks those cycles mapped stay mapped and resident afterwards — a few live
objects in most chunks keep each one (12.7 MB of chunks at a 4 MiB threshold,
against 8.5 MB when the threshold never left 4 MiB). Starting low and taking
the cheaper of two cycles removes both; a collection-bound process (pacing
active) still reaches the 8 MiB floor and pacing after its third major.

### Breakdown after the fixes

Peak sample, median of two runs each, kB (`attr/table.md`, `attr/gcry-final-json-*.json`):

| category | Boehm | gcry tip | gcry final |
|---|---:|---:|---:|
| size-class chunks | – | 10 626 | **5 250** |
| large chunks (resident) | – | 1 240 | 1 248 |
| other anonymous | 7 312 | 656 | **96** |
| libc heap | 40 | 108 | 190 (the 86 KB `Heap` now comes from `brk`) |
| everything else | 9 280 | 9 624 | 9 684 |
| **total = VmHWM** | **16 632** | **22 254** | **16 468** |
| after `/gc-collect` | 16 632 | 14 302 | 13 322 |
| collections in the run | 1 359 | 380 | 859 |
| size-class chunks mapped (end) | – | 13.9 MB | 8.5 MB |

### Local interleaved A/B

`kemal_ab.sh ab 9 boehm=… base=e8c0327e final=41457821` (`ab/results.tsv`,
`ab/summary.txt`); medians, and final against base paired per trial
[q1, median, q3]:

| path | Boehm | base | final | final / base |
|---|---:|---:|---:|---:|
| `/json` req/s | 44 494 | 45 511 (102.3%) | 45 542 (102.4%) | [0.973, **0.986**, 1.020] |
| `/` req/s | 67 512 | 67 533 (100.0%) | 69 685 (103.2%) | [1.007, 1.049, 1.074] |
| `/json` VmHWM | 15.9 MB | 21.1 MB (1.32×) | **15.7 MB (0.98×)** | [0.742, 0.745, 0.756] |
| `/` VmHWM | 16.1 MB | 21.0 MB (1.31×) | **15.6 MB (0.97×)** | [0.742, 0.745, 0.747] |

`/json` req/s is within its spread (min–max 41–49k for `final`, 44–47k
for `base` across the nine trials).

## Perf A/B on all five runners

Nine GC rows, 15 interleaved reps, Boehm arm, Kemal `/json` and `/` 15
trials (`wrk -t2 -c50`), `base` = `e8c0327e` (`origin/release-0.37.0`).
Tables: `ci/<run>-<runner>/summary.md`, `kemal-summary.md`, raw `runs.json`.

| run | id | `var` |
|---|---|---|
| atomic | [38946440792](https://github.com/sdogruyol/gcry/actions/runs/38946440792) | `fa51f65f` (atomic quarter only), branch `probe-kemal-rss-atomic` |
| floor | [38951356776](https://github.com/sdogruyol/gcry/actions/runs/38951356776) | `41457821` (all four commits), branch `kemal-rss` at the time, now `kemal-rss-floor` |
| superseded | 38946444226 (`5ebcaabf`), 38947823275 (`6776e84a`) | cancelled: the floor was revised (start low, two-cycle cost) |

Kemal `/json` peak RSS × Boehm (req/s % of Boehm), base → var:

| runner | atomic run | floor run (all four) |
|---|---|---|
| ubuntu-latest | 1.38× → 1.27× (102.9% → 106.7%) | 1.28× → **1.05×** (104.3% → 105.3%) |
| ubuntu-24.04-arm | 1.19× → 1.08× (104.5% → 105.0%) | 1.50× → 1.18× (103.4% → 106.0%) |
| macos-latest | 1.67× → 1.37× (105.1% → 105.7%) | 1.67× → 1.40× (105.9% → 96.3% [88.9, 106.2], a noisy run: Boehm itself 55k against 77k req/s in the other) |
| macos-15-intel | 1.58× → 1.44× (109.1% → 110.3%) | 1.57× → 1.43× (113.0% → 110.1%) |

`/` on the floor run: 0.99× (x86), 1.04× (arm64), 1.13× (M1), 1.05× (Intel).
macOS `/json` stays at 1.4×; not attributed here (Darwin keeps a 1 MiB
large cache, 512 KiB dormant retain and 256 KiB chunks).

crystal-metric, var against base, whole-process wall, median [IQR] where it
moved beyond its spread (every other row and runner inside it):

| run | row | runner | wall | peak |
|---|---|---|---:|---:|
| atomic | Revcomp | macos-15-intel | +6.1% [+2.9, +11.0] | −1.8% |
| atomic | JsonParsePull | macos-15-intel | +4.9% [+0.7, +10.9] | −0.9% |
| floor | **Binarytrees** | **ubuntu-latest** | **+3.3% [+0.9, +6.0]** | −8.4% |
| floor | **Binarytrees** | **ubuntu-24.04-arm** | **+2.7% [+0.2, +3.8]** | −12.9% |
| floor | Revcomp | windows-latest | −4.3% [−5.0, −3.3] | −0.1% |

Both macOS Intel cells are back inside the spread in the floor run (Revcomp
+3.3% [−2.1, +6.1], JsonParsePull +0.9% [−2.0, +4.8]), which includes the
same commit; that runner's spreads are ±5–10 points. The Binarytrees cells
are not noise: the atomic run had Binarytrees at −1.5% / −2.4% on the same
runners, and the floor run collects 3–6.5% more often there — the cost floor
comes below 8 MiB in Binarytrees' cheaper phases. Peak RSS: every row at or
under 1.1× Boehm on every runner except Knuckeotide (base 1.37–1.98×, floor
run 1.16–1.53×, atomic run 1.23–1.58×), which was over before and is
KnuckeotideRss's.

Timed sections (not the % of Boehm cells): the JSON parse rows collect
15–25% more often with the atomic quarter, and their timed section is
+1–5% where the IQR excludes zero (M1 JsonParseSerializable +4.5%, Pull
+5.6%; x86 +2.5% / +1.6%; arm64 +1.5% / +0.9%), wall unchanged.

## Decision

- **Kept:** `fa51f65f` (atomic quarter) and `6776e84a` → `a975d5cd` on
  `kemal-rss` (research tables). The first's only out-of-spread wall cells
  are Intel macOS ones the second run does not reproduce; the second
  changes no schedule.
- **Not kept on `kemal-rss`:** `5ebcaabf` and `41457821` (the cost floor),
  parked on `kemal-rss-floor`. They are what takes Kemal to Boehm's peak
  (Linux x86 1.05×, local 0.98×) but cost Linux Binarytrees 2.7–3.3% wall,
  beyond its spread. A lower target (1% instead of 2%, floor = cost × 100)
  would keep Kemal at 4 MiB (median cost 33 KB → 3.3 MB) and halve the
  region Binarytrees falls into; unmeasured.

Kept commits measured together: not separately A/B'd locally; the local
A/B above is the four-commit build. [INFERENCE] With the two kept, Linux
Kemal `/json` is the atomic run's 1.27× less the 0.47 MB of `Heap` tables,
~1.24×.
