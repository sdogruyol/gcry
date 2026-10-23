# The slow path's wipe on every target: from the entry's SP on Darwin, and on Windows (2026-10-23)

Branch `wipe-platforms-039`, on `release-0.39.0` (`6fc6665c`; the base the
perf runs compare against is `ff1c6a7a`, the same `src/`). Follows
`../2026-10-22-regexdna-peak/` (the wipe, its "Bound" and "Windows"
sections). Crystal 1.21.0 (LLVM 20.1.8) everywhere.

Two open items of 0.39.0:

- **2b, Darwin.** The bounded wipe read its bound (`Fiber.current?`, a
  call to the thread-local accessor) in the frame that then wiped, and on
  aarch64 Darwin that frame had a word nothing wrote. The wipe started below
  the frame, so that word was neither written nor wiped. Regression 86's
  stale-word count could not see it, and no CI job ran 86 on macOS.
- **5, Windows.** Windows had no wipe (stack growth through `PAGE_GUARD`) and
  so, since `wipe-windows-039`, no tail calls either, and none of the
  Knuckeotide gain: 1.63–1.73× Boehm's peak on windows-latest.

## 1. The change

`Heap#malloc`/`malloc_atomic` end their slow path with `allocate_entry(…)`
in tail position on every target again (the `{% if flag?(:win32) %}` split
is gone). The slow path is now three hops, each `@[NoInline]`:

- `allocate_entry(size, atomic, clear)`: reads the bound,
  `Roots.wipe_limit(sp)` (the call to the TLS accessor, so it has a frame),
  packs `atomic`/`clear` into one byte and tail-calls
- `allocate_wipe(size, flags, limit)`: no frame on Linux and Windows, a frame
  record on Darwin (`push %rbp` / `stp x29, x30, [sp, #-16]!`, both words
  written). `Roots.wipe_below_sp(limit)` zeroes from the SP it was entered
  with — where the entry's frame and `allocate_entry`'s were — down to
  `max(limit, SP − 1 KiB)`, then it tail-calls
- `allocate_traced(size, atomic, clear)`, unchanged.

The wipe is one asm block, the floor's arithmetic included, on scratch
registers (`r10`/`r11`; `x9`/`x10`), and it stores downward from the SP, two
words a step. `allocate_wipe` takes four arguments with `self`: Windows x64
passes four in registers, and a fifth on the stack would have turned the
sibling call into a call.

`Roots.wipe_limit(sp)`: 0 (no wipe) without a current fiber or with *sp*
outside its stack, otherwise the page above the stack's lowest; on Windows
also never below `NT_TIB.StackLimit` (`%gs:0x10`, `[x18, #16]`), the lowest
committed address of the running stack. Crystal's `swapcontext` swaps that
field with the fiber on both Windows targets, and Windows lowers it as it
commits guard pages. So on Windows the wipe stores only into committed
pages and never touches a guard page. Nothing is lost by that: a word below
the committed part was never written, so it holds nothing stale.

Release builds, disassembled (`--cross-compile`, regression 86):

| target | `allocate_entry` | `allocate_wipe` | wipe starts |
|---|---|---|---|
| x86-64 Linux | six pushes and `push %rax`, `jmp` | no frame, `jmp` | at the entry SP (0 bytes, measured) |
| aarch64 Darwin | `sub sp, #0x50`, four pairs at `0x10`–`0x4f`, accessor slot `0x8`, `[sp]` unwritten, `b` | frame record, `b` | 16 bytes below (measured) |
| x86-64 Darwin | `push %rbp` + 5 pushes + `push %rax`, `jmp` | `push %rbp`, `jmp` | 8 bytes below (measured) |
| x86-64 Windows (MSVC) | 4 pushes, `sub $0x28` (shadow space unwritten), `jmp` | no frame, `jmp` | 0 bytes (measured) |
| aarch64 Windows (GNU) | three register pairs, all written, `b` | no frame, `b` | 0 bytes (measured) |

`allocate_entry`'s unwritten words (`[sp]` on aarch64 Darwin, the 32-byte
shadow space on Windows x64) now lie inside the wiped range.

## 2. Regression 86: where the wipe starts

New check in `process_spec/regression/86_alloc_slow_path_clean_frames_spec.cr`:
while `Heap#slow_wipe_watch` holds an SP, the first slow path within 64 KiB
below it on that stack records the SP `allocate_wipe` ran at
(`slow_wipe_sp`; one load when off, scoped to the stack because gcry's own
threads allocate too — the first, unscoped version recorded a helper
thread's slow path, 7.5 TB away). The spec allocates from a frame whose SP it
reads (not a tail call), and asks for the wipe to start within 16 bytes (a
frame record) of the SP the allocation entry was called with. The stale-word
count and its control arm are unchanged and now run on Windows too
(`--release`).

Red tree: `release-0.39.0` plus only the recording (in the old
`allocate_entry`, before its wipe), the same spec. Green: this branch.

| target | red: wipe starts | red: stale words (fixed arm) | green: wipe starts | green: stale (control / fixed) |
|---|---:|---:|---:|---:|
| x86-64 Linux (local) | 56 bytes below, **fails** | 0 | 0 | 2 / 0 |
| macos-latest (M1) | 96 bytes below, **fails** 9 of 9 | 0 | 16 | 2 / 0 (15 of 15) |
| macos-15-intel | 72 bytes below, **fails** 9 of 9 | **1** | 8 | 2–4 / 0 (15 of 15) |
| windows-latest x86-64 | (no wipe) | — | 0 | 10–11 / 0 (15 of 15) |
| windows-11-arm | (no wipe) | — | 0 | 0 / 0 (15 of 15) |

On Intel macOS the gap held a stale word: the old tree's fixed arm counted 1
pattern word left between the allocation and the collector in all three
layouts, 3 of 3 runs each. On the M1 the word `[sp]` of the old frame
happened to be overwritten by `allocate_traced`'s register save, so only the
wipe-start check sees it there.

Probe workflows (push-triggered `probe/wipe-platforms`, deleted after;
`probe/wipe-platforms-red` held the red tree):
[39921866765](https://github.com/sdogruyol/gcry/actions/runs/39921866765)
(macOS fix and red, Windows x64) and
[39923030797](https://github.com/sdogruyol/gcry/actions/runs/39923030797)
(Windows x64 and arm64 with the counts printed). Regressions 79 and 86,
three layouts (default, headers, freelist), `--release` 5 runs each (red: 3)
and debug 2 (macOS) or 5 (Windows) runs each. Every fix-tree run passed.
(The first Windows arm64 job failed to link: the probe script set `CC` to
the compiler, and Crystal links with `$CC`.)

### The guard arms on Windows

Regression 86's guard-page arms used to skip on Windows. There a stack
grows downward by touching its `PAGE_GUARD` page, and a deep fiber dies of
`STATUS_STACK_OVERFLOW` 64 KiB before the reserve's end, so the arm measures
against `StackLimit` instead: a child fiber recurses until 700–1000 bytes
are left above it and wipes. Fixed child: `StackLimit` unchanged, floor
exactly at it. Control child (the first version's unbounded 1 KiB loop):
Windows commits the guard page it reaches and `StackLimit` drops by 4096 —
the child lives, and the arm asserts that the limit moved. Both Windows
runners, all layouts, debug and release: fixed unchanged, control −4096, in
every run (39923030797). Outside Windows the arms are as before (the control
child dies with "Stack overflow").

### Regression 79 on Windows

The bound is under 64 stale words; regression 79 now prints its count
(`stale79:`). With the wipe and the tail calls (39923030797):

| runner | debug default / headers / freelist | release |
|---|---|---|
| windows-latest x86-64 | 12 / 12 / 17 | 0 / 0 / 0 |
| windows-11-arm | 2 / 2 / 2 | 0 / 0 / 0 |

The tail calls without the wipe read 75 in debug on x86-64 (run
39775800632). Locally, x86-64 Linux: debug 3 / 3 / 4, release 0.

## 3. CI

- `ci/windows.ps1` (samples suite, both Windows jobs, three variants) builds
  regressions 79 and 86 `--release` and runs them: the process specs there
  are debug, where 86's stale-word check skips.
- `perf-smoke-macos` runs `make alloc-entry-frame` after its perf gate: the
  only macOS job. macos-15-intel has no CI job; the probe above is its
  evidence.

## 4. Keep rule: five runners

`Perf A/B` [39923071007](https://github.com/sdogruyol/gcry/actions/runs/39923071007):
var `2f8abfaa` (this branch; `src/` as at `a2c215de`), base `ff1c6a7a`
(`release-0.39.0`), 15 interleaved reps, ten rows, Boehm arm, `stats=3`,
extra arm `GCRY_SLOW_ENTRY_WIPE=0` (`var_env`), all five runners green
(`perf-<runner>/summary.md`). % of Boehm's speed / × Boehm's peak, median
[IQR], base → var:

| runner | Knuckeotide peak | wipe off | rows slower, IQRs apart |
|---|---|---|---|
| ubuntu-latest | 1.31× [1.21, 1.40] → 1.34× [1.22, 1.36] | 1.48× | Revcomp 85 → 83, JsonParseSerializable 92 → 90, JsonParsePull 92 → 90: placement (below) |
| ubuntu-24.04-arm | 1.26× [1.22, 1.34] → 1.25× [1.21, 1.36] | 1.26× | none (Revcomp 100 [99, 100] → 98 [98, 99]) |
| macos-latest | 1.32× → 1.32× | 1.32× | none |
| macos-15-intel | 1.56× → 1.56× | 1.56× | none (Binarytrees 155 [146, 158] → 151 [139, 154]) |
| windows-latest | **1.81× [1.64, 1.87] → 1.59× [1.46, 1.67]** (paired −13.7% [−17.7, −4.9]) | 1.58× | none (Binarytrees 123 [120, 126] → 120 [115, 121]) |

Windows gets back what the tail calls and the wipe bought elsewhere:
Knuckeotide 1.81× → 1.59×, RegexDna 0.47× → 0.43× and Revcomp 0.61× →
0.57× (paired −7.3% and −6.8%, as the tail calls alone gave there in Perf
A/B 39738092074 before the split). On Windows, as on Darwin, the wipe-off arm reads as var
on Knuckeotide (1.58×): there the tail calls alone take the holder away.
Every row other than Knuckeotide stays within 1.1× Boehm's peak except
Brainfuck on macos-latest, 1.23× in base and var alike (4 MiB).

**Windows Binarytrees** reads +3.6% wall paired [+1.9, +6.1] in that run,
and the wipe-off arm the same (119%). Same-session pads,
[39928996474](https://github.com/sdogruyol/gcry/actions/runs/39928996474)
(`pads-windows-latest/`, Binarytrees, Knuckeotide, Brainfuck): var against
base +1.8% [−1.7, +5.2], and base padded by 16 reads var's time (1.183 s,
var 1.183 s, base 1.144 s). Placement. Knuckeotide's peak in that session:
1.78× → 1.74× (paired −3.3% [−19.0, +4.2]); it is the noisiest peak on
this runner (IQRs 0.2–0.3× wide in every arm).

**ubuntu-latest**: Revcomp, JsonParseSerializable and JsonParsePull are
1.4–3.0% slower paired, and Brainfuck, which allocates nothing, +4.7%; the
wipe-off arm reads the same. Same-session pads,
[39930588292](https://github.com/sdogruyol/gcry/actions/runs/39930588292)
(`pads-ubuntu-latest/`, timed section, s): every row var is slower on has a
padded var at or under base —

| row | base | var | var +16 | var +64 | base +16 | base +64 |
|---|---:|---:|---:|---:|---:|---:|
| Revcomp | 1.554 | 1.579 | **1.474** | 1.551 | 1.466 | 1.538 |
| JsonParseSerializable | 0.748 | 0.759 | **0.725** | 0.760 | 0.704 | 0.745 |
| JsonParsePull | 0.731 | 0.758 | **0.719** | 0.748 | 0.686 | 0.736 |
| JsonGenerate | 1.362 | 1.379 | 1.420 | **1.365** | 1.419 | 1.376 |
| Brainfuck | 4.978 | 5.105 | 5.209 | **4.963** | 5.082 | 5.196 |
| Binarytrees | 1.211 | 1.194 | 1.203 | 1.213 | 1.198 | 1.222 |

— and the base itself moves 5–10% with 16 bytes of padding, as
`../2026-10-22-0.39-keep-rule/` found on this runner. Placement.
**Keep rule: holds on all five runners.**

## Open

- macos-15-intel runs regressions 79/86 only in a probe; CI has no Intel
  macOS job.
- `windows-11-arm` is not a perf-ab runner; its evidence is the probe
  (regression 79 debug 2, release 0; 86 green).
