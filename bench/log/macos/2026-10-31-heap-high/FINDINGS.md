# The macOS heap at 16–32 TiB (2026-10-31)

The question (ROADMAP, "JsonGenerate's high peaks on macOS are not boundary
words"): on both macOS runners JsonGenerate's peak lands on a high level (one
more dead 32–128 MiB `IO::Memory` buffer kept) in 35–80% of reps, with or
without the 4 GiB fence. The kernel put the heap at 4–8 GiB, right after the
executable, where 33-bit integers point; on the M1 a `5 000 000 000` in a
system library's `__DATA` was one holder
(`../2026-10-23-jsongen-m1/`). Does mapping the heap far above that take the
high levels away?

**Answer: yes, all of them on both Macs.** JsonGenerate reps on a high level
(`hp.py`: more than 15 MiB over the runner's floor), three sessions:

| run (reps) | runner | base | `var_env` (`GCRY_HIGH_HEAP=0`, same binary) | `var` (high heap) |
|---|---|---:|---:|---:|
| 41203146054 (40) | `macos-latest` (M1) | 34/40 | 37/40 | **0/40** |
| | `macos-15-intel` | 13/40 | 7/40 | **0/40** |
| 41207913078 (15) | `macos-latest` | 14/15 | 12/15 | **0/15** |
| | `macos-15-intel` | 12/15 | 12/15 | **0/15** |
| 41212311272 (20) | `macos-latest` | 15/20 | — | **0/20** |
| | `macos-15-intel` | 15/20 | — | **0/20** |

Pooled, `var` against base and `var_env`: M1 0/75 against 112/130 (Fisher,
two-sided, p = 4 × 10⁻³⁹), Intel 0/75 against 59/130 (p = 4 × 10⁻¹⁵).
41212311272's placement arms agree: `var`'s source padded by 16 or 64 bytes
0/20 each on both Macs, base padded 30/40 (M1) and 25/40 (Intel)
(`runs/hp-*.txt`).

M1's JsonGenerate peak × Boehm's in 41203146054: base 0.74× [0.67, 0.74],
`var_env` 0.74× [0.74, 0.74], `var` **0.64× [0.64, 0.64]** (−13.6% against
base, paired); in 41207913078 base 0.78×, `var` 0.64× (−27.0%). The
placement also lowers Intel's Revcomp and RegexDna peaks against the same
binary without it (−20.7% and −24.7%, §5). No row slower beyond its spread
against base that the same binary without the placement, or code placement
alone, does not move as much (§5).

**Shipped, on by default on macOS; `GCRY_HIGH_HEAP=0` turns it off.** Linux
and Windows build the same machine code as before (§4).

## 1. Where the heap was, and what is up there

The layout probe (probe run 41203118928, job "green", `lay.cr`: eight 32 MiB
blocks and small garbage, then `sudo vmmap -w -interleaved`), with
`GCRY_HIGH_HEAP=0`:

- M1: the executable at `0x102490000`, the heap's chunks `0x102660000` to
  `0x11a0b0000` among malloc's tiny regions and dyld's allocations, stacks at
  `0x16d…`, the shared cache's library data at `0x1ed9…`–`0x1f04…`. Every
  33-bit integer from 4.3 to 8.5 billion lands in that range; a heap of
  JsonGenerate's size (about 1 GiB) from `0x102660000` up covers
  `5 000 000 000` (`0x12a05f200`).
- Intel: the heap's chunks at `0x10da67000` to `0x120d19000`, as on M1.
  Above the heap, the next mappings past 4 TiB are the malloc nano zone at
  `0x600000000000`, secondary thread stacks at `0x700009bfa000`, malloc's
  helper zone at `0x7fcd…`, the main stack at `0x7ff7b…` and the shared cache
  at `0x7ff80…`.

Above 8 GiB on M1 (probe run 41207947950, `runs/layout-41207947950-m1.txt`):
the shared cache runs to `0x2acbb42a0` (10.7 GiB) and malloc's small regions
sit at `0xbccc00000` (51 GiB); with the placement the heap was at
`0x1d58a1c00000`–`0x1d58b36f4000`, every chunk, the eight 32 MiB blocks
packed in a row above the base. (The listing stops at 80 regions, inside the
heap; what lies above it on M1 was not listed.) Intel's listing is
`runs/layout-41203118928-intel.txt`, its heap at
`0x123ab9c00000`–`0x123acb699000`.

The range 16–32 TiB is empty on both. The user address space is 47 bits on
both (`MACH_VM_MAX_ADDRESS`, `0x7FFFFE000000` on arm64 macOS, `0x7FFFFFE00000`
on x86-64) [INFERENCE: from XNU's `vm_param.h`, not read on the runners; the
nano zone at 96 TiB on Intel bounds it from below].

## 2. The change

`src/gcry/os_memory.cr`, macOS only. `Gcry.os_map_placed` and
`Gcry.os_reserve_placed`, which every heap mapping goes through (size-class
chunks, large chunks and their growth reservations, the out-of-memory
reserve), ask the kernel for the mapping at `Gcry.high_heap_base` first
(`heap_map`, `heap_reserve`). The base is 2^44 plus a random multiple of
2 MiB below 2^44 (23 bits from `arc4random`, chosen by whichever thread maps
first, compare-and-set), moved off a 4 GiB boundary if it lands on one.

- **A hint, never `MAP_FIXED`.** Darwin's `mmap` without `MAP_FIXED` starts
  its search for a free range at the address, so the heap packs first-fit
  upward from the base and reuses the holes its own unmaps leave. A mapping
  refused there is asked for again without the hint, and one the kernel put
  below the base is kept; both count in `Gcry.high_heap_misses`. In every
  counter run of 41203146054 (3 per arm per runner) and every probe child the
  count was 0.
- **The 4 GiB fence** sits on top unchanged: the base is never in a window,
  and a mapping that reaches one goes back as before (`four_gib_fences`: 0 or
  1 per run on both Macs in the counter runs, as before).
- **Random, not fixed.** A fixed base would put the heap at one address in
  every process; the kernel's placement followed the executable's slide. With
  the base random, a word naming the heap is a real address or an integer
  past 2^44 — counts, sizes, times in seconds or milliseconds since 1970
  (2^40.7 now) and flags never are.
- **Costs.** The chunk index (`chunk_radix.cr`) keys on address bits 32–47,
  so the heap takes as many 4 GiB regions as anywhere else. The heap bounds
  get tighter: the heap no longer shares its range with malloc and dyld.
  Collector side mappings (mark stack, radix tables, bitmap pools) stay where
  the kernel puts them; they hold no blocks.
- `Gcry.map_hint` (specs) stands for the kernel's answer and no longer
  places a heap mapping while the high placement is on;
  `spec/four_gib_fence_spec.cr`'s `with_hint` turns the placement off around
  its mappings on macOS, so the fence examples still test the fence where the
  kernel answers.

## 3. Regression 92

`process_spec/regression/92_darwin_high_heap_spec.cr`. Each arm in a process
of its own; `Gcry.map_hint` stands for the old placement, at the 1 MiB below
`5 000 000 000`; a class variable holds the constant (static data, a root,
as the library's word was); a 32 MiB block is asked for, dropped, and the
heap collected twice.

- control (`GCRY_HIGH_HEAP=0`): the block covers the constant, the word
  names it and the collection keeps it (`high92: control: block at
  0x129f00000 covers 0x12a05f200 and the collection kept it`). It skips with
  a marker where the constant's address space is already taken.
- fixed: the base is in [2^44, 2^45), every chunk of the heap, its first
  mapping included, lies at or above it before and after, the block is above
  it, the constant names nothing and `high_heap_misses` does not move.

Probe run 41203118928 (`runs/probe-41203118928.txt`), on `macos-latest` and
`macos-15-intel`, both layouts (`-Dgcry_block_headers` too):

- green (the tree): regression 92 and `spec/four_gib_fence_spec.cr`, 10 of
  10 each; the fixed child put the heap at `0x1b9cdbc00000` (M1) and
  `0x1305d5c00000` (Intel). The unit suite (296 Intel), `process_spec` (246)
  and `process_spec -Dgcry_block_headers` (247) pass on Intel; on M1 297 (2 pending), 246 (1 pending) and 247.
- red (`high_heap_hint` returning 0, the placement gone): the fixed child
  fails at its first check, the heap's lowest chunk against the base
  (`Expected 4348919808 to be GreaterOrEqual 21850985857024` on M1,
  `4473188352 … 27281321885696` on Intel), on both runners and both layouts;
  the control passes.

Linux and Windows leave the examples pending (`process_spec` on Linux
x86-64: 302 and 303 examples, 2 pending).

## 4. Linux and Windows

The placement is behind `{% if flag?(:darwin) %}`; elsewhere `heap_map` and
`heap_reserve` are `os_map` and `os_reserve`. `samples/hello.cr` built
`--release --no-debug` from base (`bf607374`) and from this branch:
the Linux x86-64 `.text` sections are byte-identical (sha256 `914532f9…`),
and so are the `x86_64-windows-msvc` objects' (`235678bb…`). So the keep rule
on those three runners is base against itself; it was not run there.

## 5. Keep rule

Nine benches, both Macs, 15 reps, Boehm, `var_env` = `GCRY_HIGH_HEAP=0`
(Perf A/B 41207913078 at `dbdc7fe9` against `bf607374`;
`perf-41207913078/`, `runs/pair-41207913078.md`, which adds `var` against
`var_env` per rep). Wall or peak beyond the interquartile range against base:

- `macos-latest`: wall none slower (JsonParsePure −2.5% [−5.7, −0.2],
  faster). Peak: JsonGenerate −27.0%; JsonParseSerializable +3.5% [+1.7,
  +4.9], and `var_env` +3.6% [+0.6, +9.4] with it: the binary, not the
  placement (`var` against `var_env` +0.3% [−4.5, +3.3]); 41212311272 reads
  it −0.8% [−6.7, +1.5]. The timed section (not wall) of Revcomp read +5.5%
  [+0.4, +15.9] (`var` against `var_env` +2.4% [−0.4, +14.7]); 41212311272
  reads it +2.4% [−3.3, +11.9], wall +1.4% [−0.2, +5.5].
- `macos-15-intel`: wall none slower (Primes −4.8% [−9.5, −1.2], faster).
  Peak: JsonGenerate −6.7%, Revcomp −23.2%, RegexDna −0.0% [−24.6, −0.0];
  against `var_env` −5.9%, −20.7%, −24.7%: the placement lowers them. The
  timed section of JsonGenerate reads slower in all three sessions, +2.4%
  [+1.4, +4.7], +2.8% [+1.6, +4.1], +4.2% [+1.8, +9.2] (wall +1.2%, +1.2%,
  +1.4%, inside the spread each time), and `var_env` +2.6% [−2.8, +4.7] with
  it; `var` against `var_env` +0.1% [−0.3, +2.2]. The placement probe
  (41212311272, `runs/pair-41212311272.md`): `var`'s source with 16 bytes of
  nops ahead of all code reads +3.6% [+1.3, +4.5], with 64 bytes +0.1% [−1.8,
  +2.0]; base with them +0.0% and +2.0%. Code placement of the binary, which
  differs from base only by the Darwin placement code.

Every peak stays within 1.1× Boehm's but Knuckeotide's (1.32× M1, 1.56×
Intel, as base), the documented exception. Linux and Windows: the same
`.text` as base (§4), so nothing to run there.

## Tools

`../../linux/2026-10-26-four-gib/hp.py` (high reps per arm, unchanged; output
in `runs/hp-*.txt`), `runs/counters-*` (`bench/runner_ab/gc_counters.cr`, now
printing `high_heap_base` and `high_heap_misses`), `perf-*/` (the summaries).
The probe workflow lived on `probe/mac-heap-high` (deleted): runs
41203118928 (regression arms, suites, layout) and 41207947950 (M1 layout
above 8 GiB).
