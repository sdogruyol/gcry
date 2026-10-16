# macOS Binarytrees: where the remaining gap to Boehm is (2026-10-16)

crystal-metric Binarytrees ran at 78–81% of Boehm on `macos-latest` (M1,
3 vCPUs) in 0.35.0 and 0.36.0 (`../2026-10-15-0.36-native/`). This cut takes
the gap apart on the runners with probe builds and environment arms on one
binary, and fixes the two Darwin-specific parts it found in the allocation
hit path.

## Method

`Perf A/B` dispatched on probe branch `probe-mbt`, whose run step is
`probe.sh` (this directory) instead of `ab.sh`. The script applies
`probe.patch` (compile flags in the hit path, all off by default), builds
crystal-metric once per arm, and runs: `ab.py` (process-fresh, random order
per rep, 15 reps, Binarytrees; cells are medians of per-rep paired ratios
with the IQR), `bt.cr` (build/walk split and gcry counters, 7 reps),
`/usr/bin/time -l` / `-v` (5 reps), one `GCRY_TRACE` run per gcry arm, one
`GC_PRINT_STATS=1` Boehm run, `objdump` of the allocation entry points, and
`sample` on macOS. `analyze.py DIR` prints the tables below from a run's
artifact (the archived copies have their traces, samples and disassembly
gzipped).

| run | id | probe commit | runners |
|---|---|---|---|
| 1 | [38890633191](https://github.com/sdogruyol/gcry/actions/runs/38890633191) | `fd282567` (scripts `1d0bf6a0`) | macos-latest, macos-15-intel, ubuntu-latest, ubuntu-24.04-arm (`r1-*`) |
| 2 | [38893816121](https://github.com/sdogruyol/gcry/actions/runs/38893816121) | `7f689b52` (scripts `d8ac6129`) | ubuntu-latest, ubuntu-24.04-arm (`r2-ubuntu-*`); its macOS jobs died on bash 3.2 |
| 2 | [38894579003](https://github.com/sdogruyol/gcry/actions/runs/38894579003) | probe on `67e3745b` | macos-latest (`r2-macos-latest`), macos-15-intel |

Run 1's and run 2's `bt.cr` read the long-lived tree at the end, which kept
16 MiB live (44–80 majors, 3–5 ms each) where crystal-metric's
`long_lived_tree` is dead from creation (live set 0.1 MiB median); its
build/walk split is therefore not the benchmark's and is not used below.
`bt.cr` is fixed in `113e3901`.

Arms (compile flags of `probe.patch`): `tls2x` reads `@@tls_cursor_cache`
twice; `getspec` takes the hit path's set from `pthread_getspecific`;
`mac_tsd` reads the key's slot inline (TPIDRRO_EL0 / %gs); `shl` uses
`unsafe_shl` for the occupancy bit; `noatomic` makes the occupancy OR a
plain read-modify-write (one mutator only, a probe, not sound); `a64_lse`
builds with `--mattr=+lse`.

## Not the collector

Run 1 traces, macos-latest: 117 collections against Boehm's 109
(`GC_PRINT_STATS`), Σ pause 55 ms in a 1.05 s run (5%): mark 19, static roots
24, sweep 9 ms. The threshold sits on the 16 MiB Darwin floor (median), the
pace reaching 300% (48.8 MiB) at a few points; the live set is 0.1 MiB
median. Taking collections away buys little:

| macos-latest, wall vs `tip` | run 1 | run 2 | peak × Boehm |
|---|---:|---:|---:|
| `GCRY_THRESHOLD=64 MiB` (35 collections) | −2.4% [−5.8, −0.2] | | 1.91 |
| `GCRY_THRESHOLD=32 MiB` (67) | | −1.2% [−2.9, +0.9] | 1.08 |
| `GCRY_THRESHOLD=8 MiB` (259) | | +10.1% [+6.6, +15.8] | 0.73 |
| `GCRY_THRESHOLD_PACE=100` (131) | +2.0% [−4.4, +4.1] | +1.2% [−5.6, +4.9] | 0.95 |
| `GCRY_THRESHOLD_PACE=1000` (106) | +1.5% [−2.6, +3.2] | | 3.55 |
| `GCRY_ALLOC_PFW=0` | −0.8% [−6.1, +1.5] | | 1.79 |
| `GCRY_DARWIN_REUSABLE=0` | −2.1% [−4.2, −0.5] | | 1.79 |

User CPU is the wall time and system time is Boehm's (0.03 s) in every arm
(`time -l`). The Darwin 16 MiB floor is not what costs speed (8 MiB is 10%
slower), and pacing buys nothing measurable on this bench while it is what
puts the peak at 1.79× Boehm's 39 MiB (`PACE=100`: 0.95×). That RSS is a
separate decision (below).

## The hit path: two Darwin-specific costs

`sample` on the M1 (run 1, `r1-macos-latest/sample-tip-2.txt.gz`, main
thread, ~600 samples): `Heap#malloc` 45%, `_tlv_get_addr` 14%,
`TreeNode.new` 15%, `__crystal_malloc64` 9%, `TreeNode#check` 8%,
`UInt64@Int#<<<Int64>` 4%, Crystal's `Gcry::Heap::tls_cursor_cache`
accessor 2.5%.

1. **The `@[ThreadLocal]` read.** Crystal reads a thread-local through a
   `NoInline` accessor, and on Mach-O that accessor calls the variable's TLV
   thunk (`tlv_get_addr`). `tls.cr`: one read costs 1.7 ns on the M1 (Linux
   x86 1.5–1.9, Linux arm64 1.06) and **10 ns on the Intel Mac**
   (`pthread_getspecific` 6.3–7 ns there). Pricing it in the benchmark by
   adding a second read (`tls2x`): +8.9% on M1, **+28.9%** on Intel, +9.7%
   Linux x86, +6.4% Linux arm64.
2. **`Int#<<` out of line.** Crystal's macOS release links LLVM 15.0.7
   (Linux: 20.1.8), whose inliner leaves `UInt64#<<(Int64)` — the
   occupancy bit `1_u64 << bit` — as a call with its range checks on every
   allocation (`r2-macos-latest/disasm-tip.txt.gz`, `bl _*UInt64@Int#<<<Int64>`
   before the `ldxr/orr/stxr`). Linux builds inline it.

Run 2, Binarytrees wall vs `tip`, median [IQR] of 15 paired reps:

| arm | macos-latest (M1) | ubuntu-24.04-arm (N2) | ubuntu-latest (EPYC) |
|---|---:|---:|---:|
| `tip`, % of Boehm | 81% [76, 83] | 77% [76, 78] | 88% [87, 90] |
| `getspec` | −5.6% [−9.0, −0.3] | −4.3% [−4.9, −3.4] | +2.5% [+0.2, +4.4] |
| `mac_tsd` | **−7.9% [−12.5, −5.6]** → 87% | – | – |
| `shl` | **−3.1% [−9.5, −1.2]** → 84% | +0.1% [−1.8, +1.7] | −1.4% [−3.0, +0.3] |
| `getspec_shl` | −7.6% [−10.6, −3.0] → 87% | −3.8% [−5.6, −2.2] | +1.2% [−1.5, +3.4] |
| `noatomic` | −1.5% [−4.9, +5.6] | **−16.5% [−17.9, −16.2]** → 92% | **−16.7% [−17.3, −11.2]** → 103% |
| `a64_lse` | +0.2% [−3.0, +2.0] | −6.9% [−8.4, −6.3] | – |

Run 1, Intel Mac: `getspec` **−10.9% [−14.7, −7.7]** (93% → 99% of Boehm).

`pthread_getspecific` is a call on glibc too and slower than Crystal's TLS
there (3 ns), so the change is Darwin-only.

## The fix (`6bf33635`, `c59e6406`)

- `fast_alloc` shifts with `1_u64.unsafe_shl(bit)` (`bit` is 0..63: `mask`
  is nonzero). No IR change where the inliner already folded it.
- On Darwin the hit path (`Heap#cursor_set_hit`) reads this thread's set
  from the heap's own pthread key slot — the key `cursor_set_under_lock`
  already sets for the exit destructor — with `Platform.tsd_read`: `mrs
  tpidrro_el0` (low 3 bits masked) / `movq %gs:(,key,8)`, what libpthread's
  `pthread_getspecific` is (`_pthread_getspecific_direct`), and how Go's
  runtime reads `g` on darwin/arm64. Soundness: libpthread clears a thread's
  slot before its exit destructor and `pthread_key_delete` clears it in
  every thread (`pthread_tsd.c`), so a recycled key starts empty; sets are
  freed only by `destroy`, and reused only after their owner's destructor
  ran (or in a fork child). The slot index is published as one word
  (`@cursor_tsd_slot` = key + 1) after the inline read is checked against
  `pthread_getspecific` on the claim; any disagreement keeps the hit path on
  the Crystal thread-local for the heap's life. Every other reader
  (fallback set, in-flight clear, fork reset, mark shortcut) still uses
  `cursor_set_cached`.
- Spec: `spec/cursor_cache_lifetime_spec.cr` — the hit path goes through
  the key slot on Darwin only (`Heap#cursor_set_from_tsd?`; the method does
  not exist before), a key recycled after `destroy` starts empty in a thread
  that used the old heap, and four threads each get distinct blocks through
  the hit path. It is a performance change, so the red arm is the probe
  above (`tip` against `mac_tsd`/`shl`), not a failing assertion.

Before/after on every platform: `Perf A/B` run
[38898225086](https://github.com/sdogruyol/gcry/actions/runs/38898225086)
(`macos-binarytrees` at `c59e6406` against `origin/release-0.37.0`, nine
crystal-metric rows, 15 reps, macOS ×2, Linux ×2, Windows) and CI
[38898228632](https://github.com/sdogruyol/gcry/actions/runs/38898228632)
were dispatched; their results were not in when this was written
[INFERENCE for the expected M1 figure: `mac_tsd` −7.9% and `shl` −3.1% in
separate arms, so ~87–89% of Boehm].

## What is left, and what it is

- **The occupancy OR is atomic, and on Linux that is the gap.** A plain OR
  (unsound with a cross-thread `free` on the same word) takes Linux x86 from
  88% to 103% and Linux arm64 from 77% to 92%; LSE atomics recover 7 of the
  16.5 points on Neoverse N2. On the M1 the atomic costs nothing measurable
  (LL/SC to an L1-resident line), so it is not the macOS gap. Removing it
  means publishing a word's allocated bits once per word (or per refill)
  instead of once per block, which every off-STW reader of `occ` (`free`,
  interior-pointer and liveness queries) would have to tolerate; not
  attempted here.
- **macOS after the fix: ~11–13 points** [INFERENCE from the arms], with
  `Heap#malloc`'s own body the largest remaining share of samples: a
  12-register frame for the inlined refill, the `clear_block` jump table,
  and Crystal's own zeroing in `TreeNode.new` after `GC.malloc` already
  zeroed (Boehm pays that too).
- **Peak RSS.** 1.79× Boehm on M1 and 1.87× on Intel come from pacing on
  the 16 MiB Darwin floor (threshold up to 48.8 MiB); `PACE=100` is 0.95×
  at no measured speed cost on macOS but costs Linux 4–7%, and lowering the
  Darwin floor to 8 MiB costs macOS 10%. A Darwin-only pacing cap would fit
  the 1.1× budget here; it was not changed because Kemal's macOS RSS and
  throughput were measured on the 16 MiB floor and would need re-measuring.
