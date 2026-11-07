# M1 JsonParsePure's peak, 0.93× → 1.06× of Boehm's: a register pin in the benchmark's driver (2026-11-06)

0.40 on `macos-latest` (Numbers2, `../2026-11-05-0.40-runners/`):
JsonParsePure peaked at 1.06× Boehm's against 0.39.0's 0.93×, with 13
collections in place of 14–16. The step fell between keep runs on
`421b09be` (0.92×) and `d7c6f89f` (1.06×). The inference was that the
growth-priced pace takes one collection fewer once some change made a cycle
cheaper. Branch `m1-peak-040`.

## Verdict

**Not the pace. A dead `JsonGenerate`, which holds the setup's 120 MiB of
scanned data, stays in a callee-saved register (`x20`) of crystal-metric's
`Benchmark::run` across the `GC.collect` that `Benchmark#_run` makes before
its timed section.** `GC.collect` saves `x20` in its own frame, and the
mutator stack scan reads the saved register as a root. The collection that
should leave 0.1 MiB scanned and a 62 MiB heap leaves 120 MiB scanned and a
274 MiB heap. The parse then runs on a heap about 110 MiB larger, and its
peak is 558 MiB where it was 489 MiB.

The commit is `19cf3a60` ("alloc: the hit path's heap fields declared first
and the word advance out of line"). gcry's allocation entry is inlined into
`Benchmark::run`, which is about 17 000 instructions with every benchmark
expanded into it, so the commit changed that function's register
allocation. Before it, the code after `IO::Memory#to_s` reused `x20`
(`mov x20, x19`). From it on, the code uses `x8` and leaves the dead object
in `x20`.

The fewer collections are a consequence. After the pinned collection the
first parse stretch starts from the 64 MiB cap instead of 13.8 MiB. The
pace's inputs are the same with and without its growth term: the arm with
the growth term off on the tip (`tipnog`) peaks at the same 558 MiB.

**No fix.** A callee-saved register at a call is live caller state, and a
conservative collector has to scan it. Nothing in the collector can tell
that this one is dead. This is the same class as Knuckeotide's stack pin in
`Benchmark::run` (ROADMAP, "Knuckeotide's peak … stack pinning in
crystal-metric's own `Benchmark::run` frame"). The row stays inside the
1.1× budget. It is not a pacing defect, so the pace is unchanged, and so is
Primes' 9-collection schedule (below).

## 1. Bisect on `macos-latest`

Probe 42257657635 (the push-triggered workflow `probe/probe-m1-peak-bisect.yml`).
Twelve trees were built with Crystal 1.21.0. JsonParsePure and Primes ran
traced (`GCRY_TRACE`, `collect_end`) and interleaved in random order, 15
reps. The arms are the src commits between `421b09be` and `d7c6f89f` and
their bases. `421b09be` and `823ca9ed` are no longer reachable from a
remote ref, so the probe used commits of the same `src` tree (`d0fa2dcd`
and `cb95cc6f`). `tipnog` is the tip (`2658369a`) with the growth term off
(`probe/tipnog.patch`). Peak is `ru_maxrss`. The setup-end collection is
the `GC.collect` `_run` makes before its timed section (`rel.py`):

| arm | src | collections | setup-end collection: scanned MiB | heap after it, MiB | peak MiB |
|---|---|---|---:|---:|---:|
| v039 | `c0d570c5` (v0.39.0) | 14: 9, 15: 4, 16: 2 | 0.1 [0.1, 0.1] | 62.2 [62.2, 62.8] | 477 [467, 487] |
| pre | `16a6804b` (`19cf3a60`'s parent) | 13: 9, 14: 5, 15: 1 | 0.1 [0.1, 0.1] | 62.0 [62.0, 62.0] | 489 [474, 493] |
| band421 | `421b09be` | 13: 11, 14: 4 | 0.1 [0.1, 0.1] | 62.0 [62.0, 62.0] | 488 [474, 494] |
| **hit** | **`19cf3a60`** | 12: 2, 13: 13 | **120.0** [120.0, 120.0] | **273.6** [273.6, 273.6] | **561** [548, 577] |
| r86 | `9f0c139d` | 13: 14, 14: 1 | 120.0 | 273.6 | 556 [548, 575] |
| band | `e2737a33` | 12: 4, 13: 11 | 120.0 | 273.6 | 561 [548, 576] |
| refin | `258f88e5` | 13: 15 | 120.0 | 273.6 | 558 [548, 573] |
| whole | `c51890f8` | 13: 15 | 120.0 | 273.6 | 556 [548, 567] |
| drain | `617a1657` | 12: 4, 13: 10, 14: 1 | 120.0 | 273.6 [273.6, 320.5] | 559 [548, 577] |
| pth | `823ca9ed` | 12: 3, 13: 11, 14: 1 | 120.0 | 273.6 | 559 [549, 575] |
| tip | `2658369a` | 12: 1, 13: 14 | 120.0 | 273.6 | 558 [548, 576] |
| tipnog | tip, growth term off | 13: 4, 14: 11 | 120.0 | 273.6 | 558 [549, 576] |

The step is at `19cf3a60` in every run, on both sides of it, and the
growth term does not move it. Primes collected 9 times in every arm's
median: tip 15 of 15, `tipnog` 14 of 15, `pre` 14 of 15, v039 13 of 15
(`runner/runs.json`).

The same twelve binaries, built on an Apple M2 Pro (macOS 26.6.2, the same
compiler and LLVM 15.0.7) and run 12 reps interleaved, give the same step
(`m2/runs.json`). `pre` and `band421` peak at 481/482 MiB with 0.1 MiB
scanned at the setup's end, and every arm from `hit` on peaks at 559 MiB
with 120 MiB scanned (`tipnog` 570).

## 2. The schedule, traced

Median per collection, runner, the majority collection count of each arm.
Scanned and heap are MiB after the collection, threshold the next one's.
"Mutator" is the time since the previous collection.

| # | pre (13 collections, 9 runs): scanned / heap / threshold, pace, mutator ms | tip (13 collections, 14 runs) |
|---|---|---|
| 6 | 109.8 / 231.0 / 192.0, 300%, 111 | 110.1 / 231.5 / 192.0, 300%, 111 |
| 7, the `GC.collect` | **0.1 / 62.0 / 13.8**, 100%, 325 | **120.0 / 273.6 / 64.0**, 100%, 334 |
| 8 | 9.2 / 76.9 / 23.0, 100%, 56 | 43.4 / 246.2 / 65.5, 114%, 102 |
| 9 | 24.8 / 96.2 / 90.1, 232%, 21 | 87.3 / 283.4 / 152.0, 238%, 57 |
| 10 | 85.7 / 178.8 / 192.0, 300%, 82 | 192.2 / 396.5 / 192.5, 300%, 140 |
| 11 | 218.4 / 347.2 / 218.4, 300%, 176 | 320.2 / **535.3** / 320.2, 300%, 176 |
| 12 | 350.3 / **480.0** / 116.8, 100%, 203 | 350.2 / 472.0 / 116.7, 100%, 75 |
| 13 | 350.3 / 480.0, the closing `GC.collect` | 350.2 / 472.0 |

The setup ends with the same 120 MiB of `JsonGenerate`'s coordinates. In
`pre` the `GC.collect` frees them and returns the chunks, a releasing
collection. In the tip it keeps them, so the next collection frees them 100
ms into the parse. That collection releases nothing, and the heap stays at
246 MiB where `pre`'s is at 77 MiB. The parse's own data then grows into a
heap that has been about 110 MiB larger since the setup, and the peak is
reached at #11 (535 MiB heap) instead of at the document's end (480 MiB).
Up to #6 the two schedules are the same, and both reach the 300% maximum
from #9/#10 on. The tip
has one collection fewer only because its first parse stretch starts from
the 64 MiB cap that the pinned 120 MiB sets, and `pre` walks 13.8 → 23.0
MiB first. With the growth term off (`tipnog`) the 120 MiB pin and the 558
MiB peak are unchanged.

## 3. The root

A diagnostic build (`m2/seed_dump.py`, applied to the tip's and `pre`'s
`src` on the M2, never a probe of the tree) prints every root word that
first-marks a block, with its source, slot and the block's first word
(`m2/seeds.txt`). At the `GC.collect` both trees seed 61 blocks from the
same sources: 15 from the stack, 34 static and 12 from threads. One stack
seed differs. In the tip, the slot at `bottom − 0x5550` holds a 48-byte
object with type id `0x10a`, and its neighbour holds `0x10b`, the
JsonParsePure (the inlined `JsonParsePure.new` writes `0x10b` into its
48-byte allocation). In `pre` neither slot holds `0x10a`. At the six collections
before it, while the setup is still running and the object is live, the
tip seeds the `0x10a` object from a deeper stack slot.

The frame-pointer chain at that collection (`m2/disasm.txt`) puts the slot
in `GC::collect`'s frame, at `fp − 0x10`. `GC::collect`'s prologue stores
`x20, x19` there (`stp x20, x19, [sp, #0x20]` with `fp = sp + 0x30`), so
the slot is the caller's `x20`. The caller is `Benchmark::run`, at
`+41588` (JsonParsePure's `_run`):

```
bl   JsonGenerate::new<Int32>      ; j
mov  x20, x0                        ; j in x20
ldr  x0, [x0, #0x18] ; ldr x1, [x20, #0x20]
bl   JsonGenerate#run
ldr  x0, [x20, #0x18]
bl   IO::Memory#to_s                ; @text = j.@result.to_s
mov  x20, x19      (v039, pre, band421)   |   mov x8, x19   (hit … tip, tipnog)
...
bl   GC::collect                    ; Benchmark#_run's first collect
```

From `19cf3a60` on, every binary keeps `j` in `x20` across the call, and
v0.39.0, `pre` and `band421` overwrite it. That holds for all twelve arms
built on the M2. Probe 42262924921 disassembles the runner's own
binaries for v039, pre, band421, hit, tip and `tipnog`, and they match
(`runner/disasm.txt`).
JsonParseSerializable's and JsonParsePull's setups, the other two
`JsonGenerate::new` sites in the function, overwrite the register in both
trees, so their peaks are the pace's trade as recorded
(`../../linux/2026-11-02-pace-growth/`).

Why `19cf3a60` moves the register: gcry's `GC.malloc`/`GC.malloc_atomic`
entry and the `Heap#malloc*` hit path are inlined into `Benchmark::run`.
`pre` calls `GC::malloc_atomic` 75 times from it and `Heap#malloc_atomic`
never, and `hit` calls them 74 times and once, a function 89 instructions
longer (16 866 → 16 955). The commit took the word advance out of line and
moved the hit path's fields. [INFERENCE] That changed the inliner's cost
for the allocation entry and, with it, the register assignment of the whole
driver. The `x20` choice follows from that and has no tie to the
collector's behaviour.

## 4. Why the earlier runs read "not placement"

Every 0.40 pad arm in Numbers2 read 1.06×. The pads put nops ahead of code
and move addresses, but they do not change LLVM's register allocation, so
the pin is in every pad arm of a tree. [INFERENCE] arm64 Linux and Windows,
where JsonParsePure sits at 1.06–1.07× for both releases, are likely the
same pin in both trees' codegen; this was not measured there.

## Files

- `runner/runs.json`: probe 42257657635, every run's `collect_end`
  fields. `runner/disasm.txt`: probe 42262924921.
- `m2/runs.json`: the same arms on the M2 Pro. `m2/seeds.txt`,
  `m2/disasm.txt`: the seed dump, frame chain and disassembly.
  `m2/seed_dump.py`: the diagnostic patch (not part of any tree).
- `summ.py` (per-collection medians), `rel.py` (the table in §1).
- `probe/`: the two probe workflows and `tipnog.patch`. The scripts they
  run are `../../linux/2026-11-02-pace-growth/probe/probe_pace.{sh,py}`.
  The probe branch `probe/m1-peak-040` is deleted.
