# The band under the collector scrub's own call, and regressions 61, 21 and 1 in suite order (2026-11-02)

Branch `scrub-band-040`, on `release-0.40.0`. Follows
`bench/log/linux/2026-11-02-reg61-flake/`, which found the band.

## 1. The band fix

`run_collection`'s scrubs (`Heap#collect_scrub` → `clear_stack_body`) zero
16 KiB below `clear_stack_body`'s SP, less `CLEAR_STACK_RED_ZONE +
CLEAR_STACK_LEAF_MARGIN` (192 bytes on x86-64 Linux, 64 elsewhere outside
Windows), where the scrub's own `memset` runs. The allocation slow path left a
chunk's data start in that band, which is the header address of the chunk's
first block. The collector's frames are built over the band and the stack
scan reads it, so the block was kept (regression 61's flake).

`run_collection` now calls `collect_band_wipe_here` after each of its two
scrubs. That is `Roots.wipe_below_sp(Roots.wipe_limit(sp))` from
`run_collection`'s own frame: the allocation slow path's frameless asm wipe,
1 KiB below the SP, bounded by the running fiber's stack (and on Windows by
`NT_TIB.StackLimit`). It runs on every target. Windows' scrub
(`OS.clear_dead_stack`) zeroes up to its SP (16 bytes short on arm64) and
leaves no band, so there the wipe is redundant but harmless. On other
architectures `wipe_below_sp` compiles to nothing. `GCRY_COLLECT_BAND_WIPE=0`
turns the wipe off (research knob, the control arm; `docs/HARDENING.md`).
With `GCRY_COLLECT_SCRUB=0` the wipe is off too.

The band's low end, read by regression 101 on x86-64 Linux, Crystal 1.21.0,
is 768 bytes below `collect_entry_sp` in debug builds and 368 in `--release`.
Both are inside the wipe's 1 KiB.

### Regression 101

`process_spec/regression/101_collect_scrub_band_spec.cr`. The hook is
`Heap#scrub_band_plant`, stored XOR-masked so the field is no root. When set,
each collector scrub writes the unmasked word over the whole band it skipped,
`[scrub_band_low, scrub_band_high)`, once its `memset` is done. The scrub
records those bounds on every collector scrub, which costs two stores. The
target is made in a `@[NoInline]` helper on a spawned fiber that then scrubs
64 KiB of its frames. With the target made directly in the spawned block, a
`--release` build kept it with no plant at all: the address-space audit found
it in that fiber's top frame, 176 bytes below the stack top. Three arms, each
in a process of its own:

| arm | debug | `-Dgcry_block_headers` | `--release` |
|---|---|---|---|
| fixed (wipe on, plant) | freed | freed | freed |
| control (`GCRY_COLLECT_BAND_WIPE=0`, plant) | kept | kept | kept |
| unplanted (wipe on, no plant) | freed | freed | freed |

The test is skipped, with a marker, on Windows (no band) and on targets
other than x86-64 and arm64.

### Keep rule

Perf A/B, `base` = `v0.39.0`, var = `scrub-band-040` at `421b09be` (the band
commit before the rebase onto `23b6689a`), nine benches, 15 reps, pads
`p16 p64 bp16 bp64`, Boehm. One run per runner: 41336525761
(`ubuntu-latest`), 41336532865 (`ubuntu-24.04-arm`), 41336539784
(`windows-latest`), 41336546414 (`macos-latest`) and 41336553179
(`macos-15-intel`). `keep.py` over all five: `ab/keep.txt`, with summaries in
`ab/`.

**14 rows are flagged, and same-session pads excuse all 14 ("placement").**
No row is unexcused. The largest: ubuntu-latest JsonParsePull +7.4% time
(var 0.757, prepad16 0.724; base 0.704..0.727), JsonParseSerializable +5.9%,
JsonGenerate +6.0% (prepad16 1.345 under base's 1.381).

Peak memory against Boehm (var arm), Knuckeotide excepted, is at most 1.07×
(arm64 and Windows JsonParsePure). Knuckeotide is 1.06–1.74×.

The rebase brings in the intel-bt commits (`19cf3a60..23b6689a`), which carry
their own keep rule. This change's delta is the same before and after.

## 2. Regression 61, 21 and 1: rates in suite order

Each binary holds a tree's own `process_spec` files in `crystal spec`'s glob
order (each worktree's directory order), cut after the last of 21, 61 and 1.
21 is the 15th file, 61 the 48th–49th and 1 the 50th–52nd. Each run is under
the shared lock, with arms interleaved by run. The 0.40 tip's arms run the
pre-16a6804b regression 61 (no spec scrub), so the src band fix is what they
measure. Crystal 1.21.0 for `-Dgcry_block_headers` ("hdr"), and 1.22.2
headerless ("hl").

| tree | hdr: 61 / 21 / 1 | hl 1.22.2: 61 / 21 / 1 |
|---|---|---|
| `87ccf4f4` | 3 / 0 / 1 of 20 | 1 / 0 / 0 of 20 |
| `f3ccc4dc` (after the pace change, before the barrier) | 1 / 0 / 0 of 15 | 1 / 0 / 0 of 15 |
| `367c3707` (after the barrier changes) | 3 / 0 / 0 of 15 | 1 / 0 / 0 of 15 |
| tip + band wipe | 0 / 0 / 0 of 15 | 0 / 0 / **1** of 15 |
| tip, `GCRY_COLLECT_BAND_WIPE=0` | 0 / 0 / 0 of 15 | 0 / 0 / 0 of 15 |
| tip + band wipe + regression 1's scrub (`374dd89e`'s spec) | 0 / 0 / 0 of 20 | 0 / 0 / 0 of 20 |

Other failures: regression 95's control arm once (`87ccf4f4` hl, already
routed to LargeCacheIncr).

**61.** Unfixed 61 failed 10 times in 100 runs on the three older trees and
0 in 30 on the tip with the wipe. With the wipe off on the tip it also failed
0 in 30, so suite order alone no longer opens a fresh chunk under the target
on the tip's allocation history [INFERENCE: the tip's src differs from
`367c3707` by the band commit, whose `clear_stack_body` changes frame;
`367c3707`'s 3 of 15 hdr against 0 of 15 with the wipe off is p≈0.11 and
not significant]. Regression 101's control arm is the deterministic evidence
for the fix. Neither the pace change nor the barrier changes moved 61:
`87ccf4f4` 4/40, `f3ccc4dc` 2/30, `367c3707` 4/30.

**21** failed in none of 160 suite-order runs on any tree, nor in 40 runs of
an instrumented prefix (below). The rate is negligible: under about 2% at
95% confidence over these 200 runs. Neither the pace nor the barrier changes
moved it.

**1** failed twice in 160 runs before its fix, on `87ccf4f4` hdr and the tip
hl. The pace and barrier trees read 0 of 60; with rates this low the
difference is not significant, and the tip's failure is with the band wipe
on. The fix is spec-side (section 4): 0 of 40 after it.

## 3. Regression 21: what was ruled out

The one sighting (Reg61's `tipdiag2pre_9`, `87ccf4f4` prefix, hdr) had all
eight control blocks live and intact after `LibGC.collect` three times. The
same run marked 21's `GC_stackbottom` example pending: "the main fiber is not
on the initial thread". The monitor had handed its scheduler to another
thread during a syscall.

A copy of 21 (`DIAG21`, in a prefix of the tip's suite up to 21) prints, per
run: controls live, `heap.enabled?`, the disable depth, collections done by
the three calls, and whether the main fiber is off the initial thread. With
more than one live, it audits the address space for each control. Probes:

| probe | runs | live controls |
|---|---:|---|
| plain | 40 | 0 in every run; enabled, depth 0, 3 collections each |
| main fiber moved before 21 (`Fiber.syscall { nanosleep 60 ms }`, the monitor's handoff) | 6 | 0 (moved=true) |
| moved inside the example: in each control's fiber before its malloc, before its `send`, or before `collect` | 3 each | 0 |
| controls allocated on a second execution context's thread (`Parallel.new("diag21", 1)`) | 3 | 0 |
| default context driven to grow (8 spinning fibers, 400 ms) | 8 | 0; the default context stayed at size 1 |

So neither the main fiber running off the initial thread nor the controls
sitting in another thread's allocation chunk produces it by itself, and no
passing run had the collector disabled or a collection skipped. Which class it
was, stale roots or blocks not reclaimed, stays open [INFERENCE: all eight
held at once points to something block-wide rather than one stale word per
block, e.g. the controls' chunk left unswept so `GC_base` still answered for
it]. No change: the check is not weakened, and the rate is under the
resolution of 200 runs.

## 4. Regression 1: a finalizable object behind a stale word

Both failures read `count=10000 drift=-1457` / `-1225`, with the 1 000-count
cycle at -1. So objects alive at the baseline were reclaimed inside the
measured window. The ambient heap at that point is 1.08–1.46 M live objects.

A copy of 1 in the tip's suite order (`D1`, Crystal 1.22.2 headerless) prints
`live_objects`, collections and `finalizer_entry_count` after each
collection. Plain, in 30 runs, the four pre-baseline collections never moved
`live`. A second copy adds a fifth collection, then a 64 KiB scrub of the dead
stack below `drift_cycle` and a sixth collection. In 1 run of 30, `live`
dropped like this:

| step | live | finalizer entries |
|---|---:|---:|
| pre3 (4th collection) | 1 436 635 | 149 |
| extra (5th) | 1 436 635 | 149 |
| scrub + 6th | 1 436 635 | **148** |
| post0 (first after the baseline) | **1 434 949** | 146 |

So a word in the dead frames below `drift_cycle` held a dead object with a
finalizer. A fifth collection does not remove it. Once the word is gone it
takes two collections: one finds the object unreachable and runs its
finalizer, and the next reclaims it and everything it reached (1 686
objects). In the original example nothing scrubs that word. It goes when the
cycle's own calls overwrite it, between the baseline and the check, and the
reclaim lands in the window. That is the -1 225..-1 457. The band wipe does
not reach it: the word is below the mutator's frame, not under the
collector's scrub.

Fix (`374dd89e`): `drift_cycle` zeroes 64 KiB below its frame before the four
pre-baseline collections, so finalizer and reclaim both happen before the
baseline. The assertions are unchanged. Result: 0 of 40, against 2 of 160
without it.

## 5. Not accepting a block-header address as a pointer to the block

`find_block_with_chunk` maps any address in `[block, block + block_bytes)` to
the block. In the block-headers layout the user pointer is `block + 16`, so
the 16 header bytes, and the chunk's data start for its first block, count as
pointers into it. In the headerless layout (the default) a block's address
*is* its user pointer, and its chunk's data start is the first block's base
pointer, so nothing interior can be dropped there [INFERENCE: the headerless
61 failures are the same word as a base pointer; 61 failed 3 of 50 headerless
runs on the older trees here, not instrumented].

What rejecting `[block, block + 16)` in the headers layout would cost and
gain:

- **Gain.** Dead words that hold a header address (the cursor's word base,
  which for a chunk's first block is `data_start`, the word measured here)
  would stop retaining blocks in that layout.
- **Cost.** One compare per accepted candidate on the mark hot path. It also
  departs from Boehm's interior-pointer rule (any byte inside the object's
  allocation). Anything that stores a header address where the scan reads
  it and relies on that to keep the block would lose the block; which of
  gcry's own paths do that was not audited here [INFERENCE: none should,
  since mutators only ever see user pointers]. Large chunks accept their
  header slot on purpose (`find_object` hands it back), and would need the
  same decision.
- It would not help the default layout at all.

Not changed. The band wipe removes the source that was measured, and in the
default layout the same word is a base pointer.

## Checks on the pushed tree

Before the push, on `421b09be` and again on the rebased `374dd89e`:
`verify.sh` (format, lint, `spec/all_specs` three ways, `process_spec`
default, block-headers and `GCRY_BITMAP_ALLOC=0`), `make windows-typecheck`,
`make darwin-typecheck`, `make alloc-entry-frame`, and `process_spec` on
Crystal 1.22.2. All passed; the results are in the report.

## Files

- `ab/`: `keep.py` output and the five runs' summaries.
- `rates/`: one line per suite-order run per arm (`loop.sh`'s summary). It
  also holds `d1`/`d1s` (regression 1's copies) and `d21.txt` (21's copy,
  plain).
- `diag1.diff` and `diag21.diff`: the instrumented copies against the
  spec. `diag21-mover.cr` is the file put in front of 21's copy for the
  move probes. Neither is committed as a spec.
