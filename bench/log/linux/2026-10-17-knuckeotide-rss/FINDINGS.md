# Knuckeotide's peak RSS: what is resident, and why

Linux x86_64, 12 vCPUs (QEMU guest, shared with other agents; every timed run
held `heavy.lock`), Crystal 1.21.0, `--release`. Revisions: `base` =
`release-0.37.0` at `e8c0327e`; `kemal` = KemalRss's `fa51f65f` + `5ebcaabf`
(atomic live bytes count a quarter in the threshold; the floor comes down to
4 MiB where collections are measured cheap); `final` = `kemal` + this
branch's two commits (pace rise limit, idle-kind chunk release).

Knuckeotide was over the 1.1×-Boehm budget everywhere (Linux 1.72–1.80×,
macOS 1.74× / 1.81×). The 0.35.0 recheck blamed "the 8 MiB floor and the
warm budget"; that was a guess. This is the attribution.

## Tools

- `kn_probe.cr` + `kn_bench.cr` (`extract.sh`: crystal-metric's Fasta and
  Knuckeotide verbatim). A `GC_set_on_collection_event` hook (both
  collectors export it) records, without allocating, `/proc/self/status`
  (VmRSS, VmHWM, RssAnon, RssFile) and gcry's heap counters at every
  collection's Start and End; `KN_PEAK=1` adds `mincore` residency of every
  chunk, small and large, and per size class × atomicity. Phase markers add
  `smaps_rollup`, `json_stats` / Boehm `prof_stats`; `KN_DUMP=1` lists live
  blocks ≥ 32 KiB, `KN_HOLDERS=1` runs gcry's holder search on blocks ≥ 1 MiB.
- `events.py` (per-collection timeline), `peak.py` (breakdown at the
  peak = the collection Start with the highest VmRSS), `knobs.sh` +
  `knobs_summary.py` (environment arms on one binary, interleaved),
  `oom_reserve_rss.cr`.
- crystal-metric A/B: `../2026-10-14-rss-budget-recheck/ab.py` (random
  arm order per rep, whole-process wall and `ru_maxrss`, medians).

## The workload

Setup: `Fasta.new(600000).run` writes 6.1 MB into an `IO::Memory` (8 MiB
buffer), `to_s` copies it (6.1 MB `String`), the THREE section is copied
line by line into a second `IO::Memory` (4 MiB) and `to_s`'d (3 MB `@seq`).
Run: `frecuency` for k = 1, 2, 3, 4, 6, 12, 18 — `seq.byte_slice(f, k)` for
every position, 3 M `String`s of 12 + k + 1 bytes (+1 atomic slack) each, into
a `Hash(String, Int32)`. The 12- and 18-letter tables hold ~140 K keys (the
LCG's period is 139 968): ~6 MB of non-atomic `Entry` arrays, rebuilt by
doubling, plus ~4 MB of key strings. Live set: 3–20 MB, nearly all atomic.

## What is resident at the peak (`raw/peak-*.txt`, 6 runs each)

The peak lands in one of two places, run to run:

**Early (collection 10, t ≈ 233 ms), base `raw/peak/base-3`: 59.1 MB**

| | MB |
|---|---:|
| file-backed (binary, libc) | 4.6 |
| anon outside gcry's chunks (stacks, malloc'd metadata, mark buffers, bss) | 1.1 |
| large chunks: the setup's 8 MiB + 4 MiB `IO::Memory` buffers, the 6.1 MB `String`, `@seq` | 17.5 |
| size-class chunks | 35.9 |
| — of which 16-byte atomic (empty, warm) | 21.4 |
| — of which 32-byte atomic (3-letter strings, just mapped) | 13.2 |

The setup's buffers are dead but held by stale slots in `main`'s frame
(`raw/explore/holders-base.txt`: the 6.1 MB `String` from three words above
`stack_top`, the two buffers through their `IO::Memory` objects, themselves
held there). They die at collection 10, when the run's frames overwrite the
slots. Boehm faces the same frame: its in-use after the pre-run `GC.collect`
is 13.6 MB. While they live, gcry's live × factor counts their 20.9 MB in
full, so the threshold and the warm budget are 20.9 MB (Boehm weighs atomic
bytes at a quarter). Then the run goes from 2- to 3-letter strings: 15 + 1
bytes → class 16, 16 + 1 → class 32 (the one-byte atomic slack, which Boehm
adds too, `EXTRA_BYTES`). The 21.4 MB of emptied 16-byte chunks stay warm —
they are within the budget and the sweep keeps them first — but only 16-byte
blocks can use them, so the cycle maps 108 fresh 32-byte chunks (13.5 MB,
`chunks_mapped` 274 → 382 in one cycle, `raw/explore/events-base-1.txt`).

**Late (collections 48–50, t ≈ 600–670 ms), base `raw/peak/base-1`/`-4`:
65–82 MB**

| | base-1 | base-4 |
|---|---:|---:|
| file-backed | 4.5 | 4.5 |
| large chunks (Entry arrays, indices, `@seq`) | 12.0 | 15.0 |
| size-class chunks | 50.5 | 63.9 |
| live at the last sweep (small + large) | 15.1 | 15.1 |
| allocated since (the threshold) | 45.3 | 54.6 |
| pace | 300% | 300% |

The cycle before ran at the 8 MiB floor (the 12-letter table had just died)
while the 18-letter table was being built: 8 MiB in ~2 ms against a 1.2 ms
mark of 9 MB of entries. Pacing read that as collections costing 55% of the
mutator time and set 240–300% of an ~18 MB live set for the next cycle; the
cycle after that measured 100% again. That one cycle's threshold is the peak.

**Not the cause** (`raw/knobs-base.md`, 10 interleaved reps on one base
binary; ranges are wide because which stale slots survive varies):

| arm | peak MB median [min, max] | collections |
|---|---:|---:|
| default | 72.2 [59.1, 78.7] | 55 |
| `GCRY_OOM_RESERVE_KB=0` | 64.7 [58.7, 79.4] | 55 |
| `GCRY_LARGE_CACHE=0` | 63.8 [58.7, 71.7] | 55 |
| `GCRY_DISABLE_PARALLEL_MARK=1` | 69.8 [58.7, 80.0] | 54 |
| `GCRY_ATOMIC_SLACK=0` | 66.8 [56.3, 72.1] | 50 |
| `GCRY_EMPTY_CHUNK_WARM_RETAIN=0` | 59.4 [58.5, 62.3] | 55 |
| `GCRY_THRESHOLD_PACE=100` | 62.7 [58.7, 66.9] | 56 |
| `GCRY_THRESHOLD_FACTOR=50` | 58.0 [47.6, 58.8] | 67 |
| `GCRY_THRESHOLD=8388608` (fixed) | 41.7 [36.7, 42.5] | 78 |

- The OOM reserve is address space only: its 4 MiB mapping reads `Rss: 0 kB`
  in `/proc/self/smaps` after a run (`raw/oom-reserve-rss.txt`).
- Large cache, parallel-mark buffers, the slack: within the run-to-run
  spread. Non-chunk anonymous memory (stacks, metadata, mark buffers, bss)
  is ~1 MB at every peak (RssAnon minus `mincore`; the kernel's RssAnon
  counter lags, which is why some rows read −1.6).
- A fixed 8 MiB threshold takes the peak to 42 MB at the same wall time:
  the peak is the schedule. No single threshold knob reaches it because two
  things size the schedule here (the atomic live bytes and one paced cycle)
  and a third (class-bound warm chunks) adds to it.

## What Boehm keeps (`raw/peak-boehm.txt`, `raw/explore/cm*`)

Boehm's probe peak is 47.2 MB in all six runs (heap ~42 MB, never
unmapped, + 4.5 MB file-backed); its crystal-metric peak is bimodal across
runs, 39–64 MB, median 40–47 by batch (same stale-slot lottery). It collects
every 4–10 ms here (108 collections against gcry's 55): its trigger,
`min_bytes_allocd = (2 × composite + atomic / 4 + roots) / 3`, barely
counts the atomic live set, and a collection is cheap. It reuses any free
heap block for any size, so a size switch costs nothing. gcry keeps live +
one threshold (+ the warm budget's empties); with the live set atomic and
paced, that threshold was 2–3× Boehm's free space.

## The candidates (sections below measured all three; see "Decision")

1. `kemal` (KemalRss, `fa51f65f`, `5ebcaabf`): atomic live bytes count a
   quarter in the threshold and the warm budget; the floor comes down to 4
   MiB where collections are measured cheap. Takes the early phase to the
   floor.
2. `a00d66ce` threshold: one cycle raises the pace by at most half
   (`Heap::THRESHOLD_PACE_STEP_PCT` = 150; falling is not limited). A
   program whose collections stay expensive reaches 300% in three cycles
   instead of one. 200 was measured too: 50 MB against 42 (`raw/explore/cm4`).
3. `4175fae8` sweep: an emptied bitmap chunk whose (class, kind) took no
   chunk in the cycle just ended is neither kept warm nor graced. Every stop
   retires the cursors, so a slot in use takes a chunk every cycle and keeps
   its empties exactly as before; only a size the program stopped using goes.
   An earlier prototype that released *every* empty chunk no cursor took
   (active classes too) cost Binarytrees 3–4% wall from chunk churn
   (`raw/explore/cm3`, arm `widle`), which is why it is per slot.

Regression specs: `spec/adaptive_threshold_spec.cr` "does not let one burst
cycle take the pace from 100% to the maximum" (got 266 before, 150 after);
`spec/empty_chunk_grace_spec.cr` "releases the emptied chunks of a size the
last cycle did not allocate" (`left=5 of 5` before, 0 after).

## Local results

crystal-metric Knuckeotide, 21 interleaved reps (`raw/knuck/`):

| arm | wall | peak median | × Boehm |
|---|---:|---:|---:|
| Boehm | 0.688 s | 40 MB | |
| base | 0.700 s | 64 MB | 1.62× |
| kemal | 0.709 s | 50 MB | 1.26× |
| final | 0.707 s | 42 MB | 1.05× |

An earlier batch with the env-gated prototype (`raw/explore/cm4`, 21 reps,
Boehm 47 MB median that batch): base 64, kemal 51, kemal + pace limit 42,
kemal + idle-kind 48, all three 42.

Probe residency (`raw/peak-final.txt`): final peaks 37.4–59.0 MB, median
50.3 (Boehm 47.2), kemal 44.0–57.9, median 53.4, base 59.0–81.6, median
64.8. The final peaks are in the 18-letter phase: pace ≤ 225% (two steps) or
a pace-100 cycle with 24 MB of Entry arrays live mid-rehash.

All rows, 7 reps (`raw/suite/`), speed % of Boehm / peak × Boehm:

| bench | base | kemal | final |
|---|---|---|---|
| Binarytrees | 94% / 0.76× | 96% / 0.75× | 96% / 0.68× |
| Primes | 103% / 0.93× | 104% / 0.94× | 102% / 0.94× |
| JsonParsePure | 101% / 0.80× | 104% / 0.82× | 100% / 0.68× |
| JsonGenerate | 104% / 0.59× | 106% / 0.59× | 104% / 0.59× |
| JsonParseSerializable | 105% / 0.76× | 105% / 0.76× | 104% / 0.76× |
| JsonParsePull | 104% / 0.76× | 106% / 0.76× | 103% / 0.76× |
| RegexDna | 98% / 0.55× | 97% / 0.55× | 98% / 0.54× |
| Revcomp | 98% / 0.58× | 97% / 0.58× | 97% / 0.56× |
| Knuckeotide | 94% / 1.81× | 94% / 1.21× | 95% / 1.03× |

On this shared host wall-time differences under ~3–4% are noise; the
runners decide speed (below).

## Runners

Perf A/B run [38948987930](https://github.com/sdogruyol/gcry/actions/runs/38948987930)
on probe branch `knuckeotide-rss-probe` at `cb536458` (= `4175fae8` + an
env-only probe commit, `GCRY_PROBE_PACE_STEP` / `GCRY_PROBE_KIND_IDLE`, that
the `var_env` arm uses to turn this branch's two changes off: that arm is
`kemal`). `base` = `e8c0327e`, 10 reps, nine rows, Kemal 5 trials, all five
runners. Raw: `raw/ci-38948987930/`. Knuckeotide peak × Boehm, and the
rows that moved:

| runner | base | kemal (`var_env`) | kemal + pace limit + idle-kind (`var`) |
|---|---:|---:|---:|
| ubuntu-latest | 1.57× | 1.11× | **1.02×** |
| ubuntu-24.04-arm | 1.29× | 1.03× | **0.93×** |
| macos-latest | 1.75× | 1.52× | 1.30× |
| macos-15-intel | 1.81× | 1.33× | 1.26× |
| windows-latest | 1.60× | 1.37× | 1.27× |

Primes, % of Boehm, `var_env` → `var` (the pace limit): x86 84 → 83, arm
96 → 92, M1 117 → 105, Intel 104 → 98, Windows 92 → 89 — lower on all
five, by up to 12 points; Windows `var` ran 10 collections against 9.
Binarytrees on Intel 126 → 120. Kemal (5 trials): req/s within the
spread, peak 1.11× → 1.02× (x86), 1.50× → 1.36× (arm), 1.68× → 1.38× (M1),
1.57× → 1.47× (Intel) against `base`.

Attribution run [38955302551](https://github.com/sdogruyol/gcry/actions/runs/38955302551),
same probe branch, `base` = `5ebcaabf` (kemal), `var_env` =
`GCRY_PROBE_PACE_STEP=10000` (kemal + idle-kind only). Raw:
`raw/ci-38955302551/`. Knuckeotide peak base → idle-kind: x86 1.17× →
1.16×, arm 1.03× → 1.13× (IQRs overlap), M1 1.54× → 1.44×, Intel 1.57× →
1.41×, Windows 1.50× → 1.44×; with the pace limit too: 0.99× / 0.99× /
1.44× / 1.24× / 1.36×. JsonParsePure's peak drops with idle-kind on every
runner (x86 0.81× → 0.70×, arm 1.07× → 0.94×, M1 1.07× → 0.92×, Intel
0.82× → 0.69×, Windows 1.08× → 0.95×). Speed base → idle-kind is
inside the IQRs on every row except Windows JsonParseSerializable (108% →
103%, IQRs [104, 110] / [99, 104]); Kemal req/s within the spread.

## Final run: idle-kind release alone, against the shipped atomic quarter

Perf A/B [38965963265](https://github.com/sdogruyol/gcry/actions/runs/38965963265),
`var` = `knuckeotide-rss` at `42144e9e` (atomic quarter + heap tables +
idle-kind release), `base` = `01b184a6` (`release-0.37.0`: atomic quarter
+ heap tables, no cost floor), 15 reps, nine rows, Kemal 5 trials, counter
runs 3 (`raw/ci-38965963265/`). This is the headline; the two runs above
had the parked cost floor in both arms and are context.

Knuckeotide peak × Boehm, base → var:

| runner | base | var | paired peak Δ [IQR] | paired wall Δ [IQR] |
|---|---:|---:|---:|---:|
| ubuntu-latest | 1.24× | 1.15× | −12.7% [−18.2, +1.0] | +0.3% [−1.2, +1.9] |
| ubuntu-24.04-arm | 1.26× | 1.04× | −13.3% [−26.3, −2.9] | +0.0% [−0.9, +1.6] |
| macos-latest | 1.56× | 1.42× | −9.1% [−10.2, −8.0] | +1.4% [−9.3, +7.4] |
| macos-15-intel | 1.70× | 1.62× | −6.2% [−9.3, −3.2] | −9.3% [−10.9, +5.8] |
| windows-latest | 1.62× | 1.45× | −10.0% [−17.7, −3.3] | +0.8% [−2.9, +5.5] |

JsonParsePure's peak −12.4 to −15.4% on every runner, Revcomp −3.4% on
both Linux runners, Windows JsonParseSerializable −4.4%. But, paired
var/base with the IQR clear of zero:

- wall: ubuntu JsonParseSerializable +1.6% [+0.8, +2.6], ubuntu Revcomp
  +0.6% [+0.2, +0.9], arm Binarytrees +1.4% [+0.3, +2.9], arm Revcomp
  +0.9% [+0.5, +1.1], Windows JsonGenerate +1.9% [+0.5, +5.7];
- peak: arm JsonParseSerializable +0.6% [+0.3, +1.1], arm JsonParsePull
  +0.9% [+0.5, +1.1].

Kemal req/s and peak within the spread on all four runners that run it.

## Decision

The keep rule for this change was: no row's speed beyond its spread on any
runner and no row's peak worse. It fails that, by 0.6–1.9% wall on five
runner-rows and under 1% peak on two (arm). So **no default change
lands**: the idle-kind release is parked as `idle-kind-release.patch`
(`b3c20ea5`, with its spec) and the pace limit as
`pace-step-limit.patch` (`a00d66ce`, with its spec; both in this directory,
`git am` applies them: Linux 1.02× /
0.93×, but Primes −1 to −12 points on all five runners). KemalRss's atomic
quarter, which removes the dead setup buffers from the schedule, is what
shipped (`fa51f65f`).

**No default change brings Knuckeotide within 1.1× on every runner
without a cost.** What is left at its peak is one paced cycle in the
18-letter rehash phase on top of a 15–25 MB live set — what pacing is for —
plus the class-bound empties. Boehm's own peak here swings 39–64 MB with
the stale-slot lottery. The budget statement is narrowed: every
crystal-metric row except Knuckeotide (ROADMAP, CHANGELOG).
