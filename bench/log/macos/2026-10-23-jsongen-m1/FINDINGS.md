# JsonGenerate's M1 peak rise is a false root, multimodal on every runner (2026-10-23)

The question (0.39.0 item 4): on macos-latest, JsonGenerate's peak read
0.64× → 0.71× [0.64, 0.77] of Boehm's with the slow path's tail call (Perf
A/B 39738092074), and 0.77× with the wipe off. What holds the extra memory?

**Answer: a false root keeping one dead `IO::Memory` buffer, on every runner
and in every arm, Boehm's included; how many reps it hits is a lottery over
addresses and layout.** Its holders are, by runner: a word in the
collector's own `scan_mutator_stack` frame left there by the call before it
(Linux x86-64: always; M1: some sessions), a 5 000 000 000 constant in a
system library's data on M1, and words in crystal-metric's own frames. A
wipe below the SP before the scan removes the collector's word and lowers
no measurable peak (section 4), so nothing ships; `scan-wipe.patch` keeps
it with its regression.

## 1. It is not a shift, it is how often a mode comes up

Per-rep peaks (MiB) of every Perf A/B since 2026-10-20 that ran JsonGenerate
(`runs.json` of runs 39381964928, 39487147696, 39660124258, 39671242540,
39682766187, 39702197449, 39702200188, 39738092074, 39789986230,
39810968089) are multimodal on **all five runners, every arm, Boehm's
included**: a 770 MiB floor and modes at 796, 826, 892, 928, 960, 1056
(Boehm: 1198, 1207, 1312, 1363). A mode is one more dead `IO::Memory` buffer
(32, 64, 128 MiB… from the output's doublings) kept through the collections
after `run`. How many reps land high varies run to run and arm to arm:
0.38.0's arm on M1 had 10 of 15 high in 39702197449, 3 of 15 in 39738092074;
the tail-call tree read 0.64× [0.64, 0.65] in 39810968089. The 0.71× was
8 of 15 reps high, the 0.77× 14 of 15.

Collections, Σ scanned and faults are the same in low and high reps
(`scanned_per_collection` equal to the MiB); the buffer is atomic, so
retaining it does not show in the scan.

## 2. The holders (first-mark probe)

`probe.patch` (`-Dgcry_hold_probe`, research only, not in `src`): every
first mark of a large block ≥ 32 MiB prints its source, the word and the
slot's offset from `collect_entry_sp`; stack/static sources stop at
`Heap.hold_probe_stop` for gdb/lldb. `reps.py` runs interleaved arms and
lists the root-sourced hits per run.

**x86-64 Linux, tip** (`runs/tlp.txt`, 60 runs, ASLR on): 6 high, every one
held by a *stack* word in the collector's own frames, `slot-entry = -1424`,
value `0xHHHH00000001` (`HHHH` = the heap's high 32 bits): 4 runs the dead
128 MiB buffer (892 MB), 2 the 32 MiB one (796 MB). gdb (`ww3.py`,
`ww4.py`, `runs/ww3.out`, `runs/ww4-writers.out`): the slot is `scan_mutator_stack`'s
`sp+0x430`, a slot that function never writes. Its writer is the vDSO's
`clock_gettime`, called by `t0 = monotonic_ns` right before
`scan_mutator_stack` in `run_collection_body`: `mov %edi, 0x10(%rsp)`
spills `clockid_t` (1, `CLOCK_MONOTONIC`) as 4 bytes into a slot whose
upper half still held the upper half of a heap address the static scan left
there. The word is the heap's 4 GiB-aligned address plus one; it recurs every
collection, so whichever large block straddles that boundary is kept. That
is an ASLR lottery, hence the modes. (First suspect, the `setjmp` buffer's
unwritten bytes, `__mask_was_saved`'s padding included: ruled out — clearing
it changed nothing, `runs/pf1.txt`.)

**M1, tip** (probe 39928559354, `runs/m1-39928559354-reps.txt`, 20 runs per
arm): var 7/20 high, 0.38-shaped base (`32ce703a`) 14/20, var with
`GCRY_SLOW_ENTRY_WIPE=0` 2/20. In 6 of var's 7 the holder is a collector
stack word at `slot-entry = -2352` holding `0x143000000` (base:
`0x141000000`), a full heap-range address, the dead 128 MiB buffer when
high, the live 256 MiB one when low. Also seen: a word `0x12a05f200`
(5 000 000 000, a constant next to a code pointer in a system library's
`__DATA` in the dyld shared cache, scanned as static data; it falls inside
the M1 heap, which sits at 4–8 GiB) kept the 32 or 128 MiB buffer in 4 of 80
runs; and stale pointers in crystal-metric's own `__crystal_main`/`run` frame
(`slot-entry ≈ +15 000`) in 2. The tail calls and the wipe move where the
collector word lands; that is the 0.64 / 0.71 / 0.77 of 39738092074.

A second M1 session (probe 39932595208, `runs/m1-39932595208-reps.txt`, 25
runs per arm, other binaries of the same sources) read the collector word in
**no** high run: var 6/25, base 5/25, every high run held by the system
library's `0x12a05f200` or by crystal-metric's own frames
(`slot-entry` +14960 to +17424). lldb found the collector word once in four
var runs (`runs/m1-39932595208-lldb-var-3.txt`): `scan_mutator_stack`'s
`sp+0x450` holding `0x133000000`, the same class as Linux's.

## 3. The fix tried: a wipe before the scan (`scan-wipe.patch`)

`Heap#scan_mutator_stack` inlined into its caller, zeroing 4 KiB below the
caller's SP (asm stores, no call; bounded by the fiber's guard, nothing on
Windows) before calling the scan, so the scan's frames are built over zeros;
`GCRY_SCAN_WIPE=0` off. Regression 92 with it: a hook called where
`monotonic_ns` is leaves a dead block's address below the SP; control arm
(wipe off) marks it, fixed arm does not (x86-64 Linux, debug and
`--release`: `control marked true, fixed marked false`). The patch applies
to `1181c404`.

## 4. It lowers nothing measurable, so it is not kept

JsonGenerate reps above 785 MiB, wipe on / same binary with
`GCRY_SCAN_WIPE=0` / tree without it:

| source | wipe | wipe off | base |
|---|---:|---:|---:|
| Linux x86-64, local, 70 reps (`runs/ab2.txt`) | 5/70 | — | 1/70 |
| M1 probe 39932595208 (probe builds) | 2/25 | 1/25 | 6/25 (var) |
| Perf A/B 39933615426, macos-latest | 5/15 | 6/15 | 12/15 |
| macos-15-intel | 8/15 | 9/15 | 8/15 |
| ubuntu-latest | 2/15 | 2/15 | 2/15 |
| ubuntu-24.04-arm | 0/15 | 4/15 | 3/15 |
| windows-latest (no wipe) | 2/15 | 0/15 | 3/15 |

Perf A/B 39933615426: var `jsongen-m1-039` at the wipe, base
`1181c404b380317d681b8e9ce35105df8c6d0a82`, 15 reps, nine benches, Boehm,
stats 3, `var_env` `GCRY_SCAN_WIPE=0` (`perf-39933615426/`). M1's
JsonGenerate × Boehm's peak: base 0.66× [0.65, 0.74], wipe 0.64× [0.64,
0.66], wipe off 0.64× [0.64, 0.74]. With the wipe and without it in one
binary M1 reads 7 high of 40 either way; base's 12/15 against var_env's
6/15 is the layout of the added code, not the wipe. On Linux the
collector's word is gone with the wipe (none in 70 probe runs,
`runs/pw1.txt`) and the rate is unchanged: a half-overwritten word
`0xHHHH00000000` in crystal-metric's own `run` frame (`slot-entry =
+13576`) holds the same buffers instead. No collector can drop a word of
the program's live frame. So the `src` change and regression 92 were
dropped from the branch.

## Open

- A half-overwritten word (a 32-bit store over a slot that held a heap
  pointer) reads as the heap's 4 GiB-aligned address plus a small number,
  and they are common in program frames. Only placement could make them
  harmless (no large mapping across a 4 GiB boundary). Not attempted.
- gcry scans system libraries' writable data on macOS as static roots, where
  `0x12a05f200` lives; Boehm registers every image's data sections too
  (`GC_dyld_image_add`). Not changed.

## Tools (this directory)

`probe.patch` (the first-mark probe), `reps.py` (interleaved arms, per-run
peak and root-sourced hits), `tl.py` (RSS polled against `GCRY_TRACE`),
`hj.py` (gdb holder search), `ww3.py` / `ww4.py` (gdb: the owning frame of
a probe word, and a watchpoint on its writer), `ll.py` + `probe.sh` (the
runner probe: lldb names the frame owning each stack holder). Probe runs
39923639168 and 39925242943 failed in the script, 39928559354 and
39932595208 are read above; `probe/jsongen-m1` is deleted.
