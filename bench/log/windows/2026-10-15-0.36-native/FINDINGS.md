# 0.36.0 against 0.35.0 and Boehm, native Windows x86_64

GitHub `windows-latest` runner (AMD EPYC 9V45, 4 vCPUs, 16 GiB, Windows
Server 2025 build 26100), Crystal 1.21.0 MSVC, `--release`. The first native
Windows measurement: until now every Windows number came from one 12-vCPU QEMU
VM (`../2026-10-06-vm-validation/`).

## Method

`Perf A/B` (`.github/workflows/perf-ab.yml`, `bench/runner_ab/ab.sh` under
Git Bash, `ab.py`), dispatched on branch `perf-native-0.36`, whose `src/` is
v0.36.0's (`git diff v0.36.0 -- src` is empty), with `-f base=v0.35.0`. Three
arms built in the job: Boehm (stock Crystal), 0.35.0 and 0.36.0. Each of 15
reps runs every bench once per arm, process-fresh, in random order; one
discarded run per binary first (Defender scans a fresh image). Cells are
medians of per-rep paired ratios with their interquartile range: speed is
Boehm's whole-process wall over the arm's, memory is the arm's
`PeakWorkingSetSize` over Boehm's. Peak working set is not Linux RSS: pages
decommitted and committed again count twice.

Every bench computed the same result in every arm, Boehm's included
(several print `err` on Crystal 1.21 under any collector).

Run [38723935225](https://github.com/sdogruyol/gcry/actions/runs/38723935225)
(raw: `runs.json`, `summary.md`).

## crystal-metric

| bench | Boehm | 0.35.0 | 0.36.0 |
|---|---:|---|---|
| Primes | 0.985 s, 665 MiB | 108% [103, 110] / 0.93× | 105% [101, 108] / 0.92× |
| JsonParsePure | 1.213 s, 518 MiB | 101% [97, 102] / 1.09× | 101% [99, 103] / 1.08× |
| Binarytrees | 0.902 s, 44 MiB | 97% [92, 105] / 0.95× | 94% [90, 105] / 0.94× |
| JsonGenerate | 2.115 s, 1 335 MiB | 105% [100, 106] / 0.70× | 104% [99, 108] / 0.58× |
| JsonParseSerializable | 1.134 s, 556 MiB | 101% [98, 105] / 0.94× | 99% [96, 103] / 0.81× |
| JsonParsePull | 1.192 s, 555 MiB | 100% [97, 107] / 0.94× | 103% [100, 107] / 0.82× |
| Revcomp | 2.377 s, 892 MiB | 98% [94, 99] / 0.75× | 95% [93, 96] / 0.61× |
| RegexDna | 3.067 s, 527 MiB | 99% [97, 102] / 0.50× | 99% [96, 102] / 0.50× |
| Knuckeotide | 0.919 s, 52 MiB | 88% [86, 90] / 1.68× | 89% [87, 93] / 1.67× |

0.36.0 against 0.35.0, paired per rep (median [IQR]):

| bench | timed section | whole-process wall | peak working set | Σ mark |
|---|---:|---:|---:|---:|
| Primes | +2.4% [−0.2, +3.6] | +2.8% [+0.4, +4.5] | −1.1% | +22.0% |
| JsonParsePure | +0.0% | −0.9% | −0.1% | +0.7% |
| Binarytrees | +0.7% | +2.7% [−1.3, +7.6] | −1.2% | −11.4% |
| JsonGenerate | −0.1% | −1.7% [−2.7, −0.5] | **−17.0%** | −7.2% |
| JsonParseSerializable | +1.4% | +1.7% [−0.3, +5.2] | **−13.7%** | +5.3% |
| JsonParsePull | +1.1% | −1.4% | **−13.1%** | +4.7% |
| Revcomp | **+7.7% [+7.1, +10.0]** | +3.4% [+1.9, +5.5] | −4.9% | −4.8% |
| RegexDna | +0.6% | +0.8% | −0.2% | −6.1% |
| Knuckeotide | +0.1% | −0.2% | −0.4% | −4.3% |

- **Memory: what in-place `realloc` growth was for holds on Windows.** The
  rows that grow buffers peak 13–17% lower (JsonGenerate 0.70× → 0.58×,
  JsonParseSerializable 0.94× → 0.81×, JsonParsePull 0.94× → 0.82×, Revcomp
  0.75× → 0.61×). Every row but JsonParsePure (1.08×) and Knuckeotide (1.67×,
  a 52 MiB process at the threshold floor and warm budget, as on Linux) is
  under Boehm's peak.
- **Speed: within 94–105% of Boehm on every row but Knuckeotide (89%)**, the
  same band as the VM's 87–114%. Binarytrees is 94% here against 112% in the
  VM; its IQR is [90, 105].
- **Revcomp's timed section regressed beyond the spread: +7.7% [+7.1, +10.0]**
  (whole-process wall +3.4%, since in-place growth speeds the setup that
  builds its input). The cause is code placement of gcry's allocation path,
  not collector work (below, and `../2026-10-16-revcomp-attribution/`).
- **Primes: +2.8% wall [+0.4, +4.5]**, with Σ mark +22% at the same 8
  collections. In-place growth on the same binary accounts for the mark;
  below.

## Attribution

### Primes: in-place growth moves where the collections fall

The `var_env` arm runs the 0.36.0 binary with `GCRY_REALLOC_IN_PLACE=0`, so
code placement is identical (runs
[38731269921](https://github.com/sdogruyol/gcry/actions/runs/38731269921),
15 reps, and
[38734279640](https://github.com/sdogruyol/gcry/actions/runs/38734279640),
20 reps; `attribution/inplace-r{1,2}-*`). In the 20-rep run, 0.36.0 against
its own in-place-off arm: Σ scanned bytes 611 against 509 MiB (+20%), Σ mark
+19.5% [+15.1, +24.8], 8 collections in both, timed section +1.8% [+0.4,
+4.1], wall +1.1% [−4.4, +4.3]; 0.35.0 scans 508 MiB. Turning in-place off
puts the mark back where 0.35.0 has it.

**Cause: the collection schedule, not a cost per byte.** Primes builds a
trie whose live set only grows, so Σ scanned is the sum of the live set at
the points where collections fall. In-place growth charges the allocation
counter only the bytes a growth adds, where a copy charged the whole new
block, so the collections move. Each collection's scanned MiB (run
[38736749890](https://github.com/sdogruyol/gcry/actions/runs/38736749890),
6 reps, `attribution/primes-schedule-*`; the same in every rep):

| arm | scanned per collection (MiB) | Σ |
|---|---|---:|
| 0.35.0 | 0, 0, 0, 47, 149, 313, 0, 0 | 509 |
| 0.36.0 | 0, 0, 19, 45, 187, 351, 0, 0 | 602 |
| 0.36.0, in-place off | 0, 0, 0, 47, 155, 318, 0, 0 | 520 |

0.36.0's third collection comes while the trie is being built (19 MiB)
instead of before it, and the last two land later in its growth. The same
mechanism runs the other way where the schedule falls differently: on
Linux and Intel macOS 0.35.0 takes 9 collections and 0.36.0 takes 8, so
Primes scans less and runs faster, and in the same run on `macos-latest`
0.35.0 took 9 in 4 of 6 reps and 0.36.0 8 in all 6, at 579 against 913 MiB
scanned (`../../macos/2026-10-15-0.36-native/FINDINGS.md`). It is a
threshold-placement effect of a bench with a monotonically growing heap,
not a regression of the collector's work per byte. The JSON rows gain on
the same flip: JsonGenerate wall −4.6% [−7.1, −3.2], Σ mark −7.9%;
JsonParseSerializable Σ mark −15.8%.

### Revcomp: the step is at the back-link commit, non-monotonic

Six dispatches with 0.36.0 as `var` and a commit between the releases as
`base` (12 reps each, `bisect/<base>-*`; runs 38733021036, 38733031381,
38733041941, 38733051799, 38733062082, 38733071648). Revcomp's timed
section, 0.36.0 against the base, median [IQR]:

| base | what it adds over the one above | Revcomp timed | Brainfuck wall |
|---|---|---:|---:|
| `123069c3` | 0.35.0 + layout removal, RSS-budget cap floor, knob removal | +8.8% [+8.0, +9.6] | +2.8% |
| `bfe05bd3` | Windows crash guard | +10.5% [+9.8, +11.0] | −0.9% |
| `0a0e3165` | `live_objects` free fix, invariant births, a `Heap` field and a branch in `counters_atomic?` | **−3.5% [−4.0, −2.7]** | −0.4% |
| `f2f25ea2` | in-place `realloc` | +7.2% [+5.1, +7.8] | −1.1% |
| `135495f5` | `free_bytes` capacity credit, crash-path inlining, `bytes_since_gc` fix | +13.2% [+12.4, +14.7] | −0.3% |
| `b1cdc0ed` | tripwire removal | +12.4% [+11.0, +12.6] | −1.3% |
| — | `49788b15` back-link, 64-byte large start; then 0.36.0 | — | — |

The last fast build is `b1cdc0ed`, so the step to 0.36.0 is `49788b15`. But
`0a0e3165`, which changes neither the large layout nor the realloc path, is
already as slow as 0.36.0, and the next commit is fast again: the timed
section moves ±12% between builds whose Revcomp-relevant code is the same.
That is the signature of code placement or data alignment, not of the
back-link's per-free store. `GCRY_REALLOC_IN_PLACE=0` does not
recover it (timed 1.459 s against 1.447 s for 0.36.0 and 1.290 s for 0.35.0,
run 38731269921). macOS arm64 shows none of it (−0.7% wall in the main run).
Linux saw the same shape smaller (`../../linux/2026-10-14-0.36-integration-ab/`:
Revcomp −3 points, Brainfuck swinging 5% between builds).

**Cause: code placement** (`../2026-10-16-revcomp-attribution/`). On an EPYC
7763, v0.36.0's own source rebuilt with nops ahead of all its code runs
Revcomp's timed section in 1.254–1.270 s in three of ten placements, as fast
as 0.35.0 or faster, and in 1.409–1.476 s in the other seven. 0.35.0 spans
1.280–1.489 s the same way. The collector's counters are the same in every
build, and 0.36.0 takes 11% fewer faults at the same kernel time. The code
whose offset mod 64 decides it is gcry's `Heap#malloc_atomic` (or
`Heap#allocate` behind it): of the functions on Revcomp's timed path, only
these two are consistent with all 61 builds timed on three CPU models. The
same rule predicted the 0.37.0 tip's placement probes, 5 of 5 on two CPUs.
In this table, `49788b15` moved `malloc_atomic` from 16 to 48 mod 64 and the
step to `0a0e3165` from 16 to 32. Large objects started at 0.35.0's offset
change nothing (−0.4%). The 95% cell and the +7.7% stay as measured. The
six commit runs above were on EPYC 7763 (`123069c3`, `0a0e3165`, `f2f25ea2`,
`135495f5`) and 9V74 (`bfe05bd3`, `b1cdc0ed`) runners, not the main run's
9V45.

## Against the VM (2026-10-06)

The VM measured 0.31-era code on 12 vCPUs; this runner has 4. Same picture:
throughput within the Linux band, peaks at or under Boehm's except
JsonParsePure (VM 1.14×, here 1.08×) and Knuckeotide (VM 1.62–1.73×, here
1.67×). Kemal is not measured here: the runner image has no `wrk`.
