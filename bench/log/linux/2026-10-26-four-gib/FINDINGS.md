# No heap mapping across a 4 GiB boundary (2026-10-26)

The question (ROADMAP, "A large mapping across a 4 GiB boundary is a false
root's target"): a 32-bit store over a stack slot that held a heap pointer
leaves `0xHHHH0000000N`, the 4 GiB boundary at or below the heap plus a small
number (`../../macos/2026-10-23-jsongen-m1/`: the vDSO's `clock_gettime` in
the collector's frame, crystal-metric's own `run` frame). Whichever block
covers the boundary is kept, at random with address randomization. Does
keeping every heap mapping off the boundaries take JsonGenerate's high peak
levels away?

**Answer: on Linux, all of them; on Windows about half; on macOS none, whose
high reps are held by other words.** JsonGenerate reps on a high level, the
same-binary control arm against the fence:

| runner | before (11 runs, 2026-10-20..23) | control: `base` + `var_env` | `var` (fence) | Fisher, two-sided |
|---|---:|---:|---:|---:|
| `ubuntu-latest` | 34/330 (10%) | 13/230 (5.7%) | **0/115** | p = 0.006 |
| `ubuntu-24.04-arm` | 31/330 (9%) | 12/230 (5.2%) | **0/115** | p = 0.01 |
| `windows-latest` | 39/420 (9%) | 32/230 (13.9%) | 8/115 (7.0%) | p = 0.07 |
| `macos-latest` | 145/420 (35%) | 115/150 (77%) | 61/75 (81%) | p = 0.49 |
| `macos-15-intel` | 136/360 (38%) | 80/150 (53%) | 33/75 (44%) | p = 0.2 |
| Linux x86-64, local | — | `GCRY_FOUR_GIB_FENCE=0` 13/250 | **0/250** | p = 0.0002 |

No row of the nine is slower beyond what code placement moves on the same
runner, and on every row the fence arm reads as the same binary with the fence
off. **Shipped, on by default; `GCRY_FOUR_GIB_FENCE=0` turns it off.**

## 1. The change

`Gcry.os_map_placed` and `Gcry.os_reserve_placed` (`src/gcry/os_memory.cr`)
are what every heap mapping goes through: `Heap#mmap_anonymous` (size-class
chunks, large chunks without room, the out-of-memory reserve, the
destination of a recycled large chunk) and `Heap#reserve_large_mapping`
(a large chunk with growth room, checked over its whole extent, since
`grow_large` commits into it where it stands). A mapping that enters a window
`[B − 1 MiB, B + 1 MiB)` around a 4 GiB boundary `B` goes back, the window is
reserved inaccessible for good (`PROT_NONE` with `MAP_FIXED_NOREPLACE` on
Linux, a hint on macOS, `MEM_RESERVE` on Windows: no memory, no commit
charge), and the mapping is asked for again. When something else holds part
of the window (a mapping not the heap's, or an earlier piece), the part the
heap mapping held and each free side of it are fenced instead. After 16 tries
the mapping is kept where it is; a mapping longer than 4 GiB − 2 MiB is never
moved. The split chunks of a recycled large chunk lie inside it, so nothing
else needs a check. The chunk index and heap bounds are untouched: fences are
not chunks.

Both sides of the boundary: `0xHHHHFFFFFFFF` is a negative 32-bit store over
a pointer one region down. Size-class chunks too, not only large ones: a dead
`IO::Memory` object there keeps its buffer.

The switch is process-wide (`Gcry.four_gib_fence=`), as the fences are. The
first build had it as a `Heap` field, which moves every later field; that
build's rows read faster and slower than base by turns (Perf A/B 40348010467,
`runs/pair-40348010467.md`), so it went.

Fences per JsonGenerate run on the runners (counter build, 10 runs each,
Perf A/B 40363356982, `runs/counters-40363356982.txt`): `ubuntu-latest` 3 of
10 runs, arm64 5, M1 3, Windows 1, Intel macOS 0; one or two fences each.
Locally the first version walked through a partly held window one remap at a
time (8 remaps in 11 of 150 runs, `runs/local-bfe-150.txt`); with the sides
fenced 1 of 100 (`runs/local-c2b-100.txt`).

## 2. The regression

`spec/four_gib_fence_spec.cr`. `Gcry.map_hint` (spec only) has the kernel put
a mapping across a boundary in address space it just gave back. Control arm
(fence off): a 32 MiB block is mapped across `B`, and `find_block(B + 1)` and
`find_block(B − 1)` name it. Fence on: the block is outside the window and
both words name nothing. The same for a 128 KiB chunk-sized mapping wholly
inside a window, and for a growth reservation whose committed front ends below
the window and whose room crosses it; a mapping beside a window stays where
the kernel put it. Red with the placement disabled (`FOUR_GIB_ATTEMPTS = 0`:
3 of 5 examples fail, each at its `in_window?` check), green with it, on both
layouts, Linux x86-64. Probe run 40371805257 (`06a14b3e`, throwaway
workflow, branch deleted): `macos-latest` and `macos-15-intel` pass all five
examples on both layouts, so XNU takes a free hint as Linux does, and
`crystal spec -Dgc_none spec/all_specs.cr` (296 and 295 examples), `crystal
spec` (306, 308) and `crystal spec -Dgc_none process_spec` (242 each) pass;
`windows-latest` runs the window example and leaves the four mapping
examples pending (Windows takes an address as a demand, not a hint), and
`ci/windows.ps1 -Variant default -Suite specs` passes (308 unit examples, 239
process) with every heap mapping going through the placement.

## 3. The rate

JsonGenerate peaks per rep, a rep high when more than 15 MiB over the
runner's floor in that run (`hp.py`; one more dead buffer is +26 MiB or
more). Runs: 40348064470 (40 reps, five runners), 40348010467 (20 reps, nine
benches), 40358937397 (40 reps, Linux and Windows), 40358917391 (15 reps, nine
benches); `var` is this branch, `var_env` the same binary with
`GCRY_FOUR_GIB_FENCE=0`, `base` `origin/release-0.39.0` (`02a16bf2`).
Per run (`runs/hp-*.txt`):

| run | runner | base | var_env | var |
|---|---|---:|---:|---:|
| 40348064470 | `ubuntu-latest` | 2/40 | 5/40 | 0/40 |
| | `ubuntu-24.04-arm` | 1/40 | 6/40 | 0/40 |
| | `windows-latest` | 8/40 | 6/40 | 1/40 |
| | `macos-latest` | 33/40 | 31/40 | 32/40 |
| | `macos-15-intel` | 25/40 | 26/40 | 21/40 |
| 40348010467 | `ubuntu-latest` | 1/20 | 0/20 | 0/20 |
| | `ubuntu-24.04-arm` | 0/20 | 1/20 | 0/20 |
| | `windows-latest` | 3/20 | 1/20 | 3/20 |
| | `macos-latest` | 12/20 | 16/20 | 15/20 |
| | `macos-15-intel` | 12/20 | 13/20 | 11/20 |
| 40358937397 | `ubuntu-latest` | 3/40 | 1/40 | 0/40 |
| | `ubuntu-24.04-arm` | 1/40 | 1/40 | 0/40 |
| | `windows-latest` | 2/40 | 4/40 | 3/40 |
| 40358917391 | `ubuntu-latest` | 1/15 | 0/15 | 0/15 |
| | `ubuntu-24.04-arm` | 1/15 | 1/15 | 0/15 |
| | `windows-latest` | 3/15 | 5/15 | 1/15 |
| | `macos-latest` | 10/15 | 13/15 | 14/15 |
| | `macos-15-intel` | 3/15 | 1/15 | 1/15 |

"Before" is every gcry arm of the eleven Perf A/B runs the M1 findings read
(`hp.py --pool`, `runs/before-pooled.txt`). Locally (Linux x86-64, 12 CPUs,
counter build, interleaved, `lr.py`): 9/150 and 4/100 high with the fence
off, 0/150 and 0/100 with it, the fence placed in 67 and 31 of those runs.

On Windows the fence fires in about one run in ten and the rate halves;
[INFERENCE] the rest of its high reps are held by other words, as on macOS.
On both macOS runners the rate does not move, though the fence fires on M1
as often as on Linux: the M1 findings' holders were full heap addresses in
the collector's and crystal-metric's frames and a `5 000 000 000` in a system
library's data (the heap sits at 4–8 GiB, where such integers land), not
boundary words. Open (ROADMAP): mapping the macOS heap far above the range
small integers reach.

## 4. Keep rule

Nine benches, five runners, 15 reps, Boehm, the final tree (`7e001ffc`;
Perf A/B 40358917391, `perf-40358917391/`, `runs/pair-40358917391.md`; its
counter step failed on base's missing counter, fixed in `1f7eac1c`, after the
tables). Wall or peak beyond the interquartile range against `base`:

- `ubuntu-latest`: JsonParseSerializable +2.5% [+1.5, +3.1] wall (var_env
  +2.2%), JsonParsePull +1.8% [+1.0, +2.4] (var_env +1.7%), Revcomp +0.3%
  [+0.1, +0.8] (var_env −0.0% [−0.3, +0.8]); peak JsonParseSerializable
  +1.8%, JsonParsePull +2.3%, Knuckeotide +4.9% [+0.3, +10.1] (var_env
  +2.6%, +1.5%, +3.6%). Binarytrees −5.8%, faster.
- `macos-latest`: JsonGenerate peak +18.3% [+2.1, +21.5], var_env +18.4%:
  14 and 13 of 15 high against base's 10, the M1 lottery (§3).
- `ubuntu-24.04-arm`, `macos-15-intel`, `windows-latest`: nothing slower
  beyond its spread.

The fence arm and the same binary without it agree on every row, so what
differs from base is the binary. Placement probe on `ubuntu-latest`
(Perf A/B 40366765606, `runs/pair-40366765606.md`): base padded by 16 or 64
bytes ahead of all code reads +0.4% to +2.9% wall on JsonParseSerializable,
+1.4% to +2.0% on JsonParsePull and +1.4% to +2.1% on JsonGenerate against
itself unpadded; this tree reads +1.8%, +2.4%, +1.6%. Revcomp: this tree +2.0%,
the same source padded by 16 bytes −2.7%; Knuckeotide's peak −8.0% to +3.2%
across the pad arms. The first build (40348010467) read JsonParseSerializable
and JsonParsePull −1.0% and −1.1% wall on `ubuntu-latest`, faster. Every peak
stays inside the 1.1× budget but Knuckeotide's, the documented exception.

## Tools

`hp.py` (high reps per arm, or pooled per runner), `pair.py` (every arm
against base, paired per rep), `lr.py` (local interleaved runs of a counter
build). `perf-*/` hold the five summaries of each run.
