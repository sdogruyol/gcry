# Knuckeotide's pinned buffer: Boehm keeps it too

Linux x86_64, 12 vCPUs (QEMU guest, shared with other agents; every timed
session held `heavy.lock`), Crystal 1.21.0 (LLVM 20.1.8), `--release`.
crystal-metric built in `bench/crystal_metric` the way
`bench/run_crystal_metric_ab.sh` builds it:

| binary | what | sha256 prefix |
|---|---|---|
| `cm-gcry` | `-Dgc_none`, gcry at `9157672e` (v0.38.0 = `release-0.39.0` when this started) | `597c821d119d6b8c` |
| `cm-gcry037` | `-Dgc_none`, gcry at `16b7e67c` (v0.37.0) | — |
| `cm-boehm` | no `-Dgc_none`: Crystal's static bdwgc, `GC_get_version()` = 0x80208 (8.2.8) | `5ed5467445195960` |
| `cm-gcry-unpin`, `cm-boehm-unpin` | the two above with the dead slots zeroed before the timed run (below) | `8a3ff670c84809b4`, `e8eaf56ff63359ef` |

The question (0.39.0 item 5): Knuckeotide's peak is 1.71× Boehm's on this
host on 0.38.0, and the 0.38 findings put the rise on a dead buffer pinned by
a stale word in crystal-metric's own `Benchmark::run` frame. Boehm is
conservative too; why does it not keep the buffer, and can gcry stop pinning
it soundly?

**Answer: Boehm does keep it.** The Boehm build spills the same dead
`String` into a slot of the same frame (`0x70(%rsp)` there, `0x40(%rsp)` in
gcry's) and marks it at every collection to the end of the run, together
with the same dead `IO::Memory` and its 4 MiB buffer. Each collector pays
about 11 MB of peak for them. Neither can drop them: the words sit in a live
frame above the stack pointer and in callee-saved registers, which no
conservative collector may treat as dead and which Boehm's `GC_clear_stack`
(below the SP only) does not reach. gcry already has that mechanism
(`GCRY_CLEAR_STACK`, and its collection-entry/exit scrub on by default), and
it changes nothing here. What separates gcry from Boehm on Knuckeotide is the
collection schedule, with or without the pin. **No gcry change.**

> **Corrected 2026-10-22** (`../2026-10-22-regexdna-peak/`). Everything
> above about crystal-metric's own frame stands: the `Benchmark::run` slots
> and the callee-saved registers are the mutator's, and neither collector
> can drop them. But they were not the only holders, and "the rest is the
> schedule" was too strong. gcry's own allocation entry, `GC.malloc_atomic`
> with the hit path inlined, was also live across every collection an
> allocation triggered, and its slots that only the hit path writes held
> dead objects. In the timed run its `0x30`/`0x60` slots held 786 KiB
> hash-entry buffers, below this directory's 1 MB `MINPAY`, so
> `holders_gcry.py` did not report them. That frame is gcry's, so gcry can
> drop it: the slow path now leaves the entry frame by a tail call and
> zeroes the 1 KiB below it (`Heap#allocate_entry`, regression 86). On the
> five perf runners Knuckeotide's peak falls from 1.44–1.78× to
> 1.28–1.63× Boehm's (Perf A/B 39738092074). What is left over Boehm is the
> crystal-metric pin both collectors pay, plus the schedule.

## Tools (this directory)

- `holders_gcry.py` (gdb): at the entry of every
  `Gcry::Heap#run_collection_body`, for every large block of ≥ 1 MB that
  `GCRY_TRACE_LARGE=1` has reported, whether its chunk is `FREED`, and every
  word of the main stack `[sp, stack top)` or register that points into it,
  attributed to the innermost frame whose SP is at or below the slot.
  `BIN=… TRACE=… [ENVS="K=V …"] gdb -q -batch -x holders_gcry.py`.
- `holders_boehm.py` (gdb): the Boehm build. `RES_PC` = the instruction after
  `Knuckeotide#initialize`'s `IO::Memory#to_s` (where `res` is in `%rax`);
  at every `GC_finish_collection` (mark done, nothing reclaimed),
  `GC_is_marked(res)` and the stack words into it. `SEQ_PC`/`SEQ_EXPR` add
  the `seq` buffer's mark bit. Boehm's suspend signals (`SIGPWR`, `SIGXCPU`)
  are passed through.
  `BIN=cm-boehm RES_PC=86f77 SEQ_PC=8733d SEQ_EXPR='*(unsigned long*)(*(unsigned long*)($sp+0x60)+0x38)'`.
- `boehm_clear_count.py` (gdb): hit counts of `GC_clear_stack`,
  `GC_clear_stack_inner` and `GC_finish_collection` over a run.
- `patch_unpin.py`: the counterfactual, without ptrace. It copies a binary,
  overwrites `Nbody#energy` (never executed by Knuckeotide) with
  `movq $0, off+8(%rsp)` per dead slot and a `jmp` to `GC.collect`, and
  retargets the `call GC.collect` that opens Knuckeotide's timed run to it:
  the same executable, every other byte unchanged, with the dead slots zero
  from the timed run on. A first try zeroed the slots from gdb instead; its
  control arm (nothing zeroed) read 91 MB on gcry, against 68 without gdb
  [INFERENCE: ptrace intercepts gcry's suspend signals, lengthens its pauses
  and so raises its pace]. gdb is used here for holders and collection
  indices only, never for a peak.
- `pool.py`: pools the interleaved sessions in `raw/ab-*.json`
  (`../2026-10-14-rss-budget-recheck/ab.py`, every (rep, bench) runs every
  arm once in random order; whole-process wall and `ru_maxrss`).
  `raw/pooled.md` is its output.

`raw/disasm-{gcry,boehm}-knuckeotide.txt` are the constructor's code in each
build; `raw/tl-*.txt` the gdb timelines.

## The holders, on 0.38.0's layout (`raw/tl-gcry-1.txt`)

`Knuckeotide#initialize` is inlined into `*Benchmark::run<(String | Nil)>:Nil`
(the macro-expanded driver: 0x17da4 bytes, frame `sub $0x3ff8,%rsp`). The
Fasta output, `res = f.@result.to_s`, is the 6 100 096-byte `String` mapped
at collection 2. The `res.each_line` loop keeps it in registers and one spill
(`raw/disasm-gcry-knuckeotide.txt`):

```
ea594: call IO::Memory#to_s      ; res -> %r15
ea61d: mov  %rbx,0x70(%rsp)      ; seq = IO::Memory.new
ea633: mov  %r15,%r14            ; r14 = res
ea636: mov  %r15,%rbx
ea639: add  $0xc,%rbx            ; rbx = res + 12 (the bytes)
ea641: mov  %rbx,0x20(%rsp)
ea646: mov  %r15,0x40(%rsp)      ; spill: res
ea6d8: add  %rbx,%rbp            ; rbp = line start inside res
ea761: mov  0x40(%rsp),%r14      ; reload in the loop
ea94c: call IO::Memory#to_s      ; @seq = seq.to_s (live, 3 MB)
ea95d: call GC::collect          ; _run, inlined: the timed run starts
ea96c: mov  %edx,0x20(%rsp)      ; 0x20 reused (low half) — the only one of the three slots rewritten
ea97c: call Knuckeotide#sort_by_freq
```

After the loop nothing reads `0x40(%rsp)`, `0x70(%rsp)`, `%rbx`, `%r14` or
`%rbp` again, and nothing writes the two slots before the run's last
collection (the timeline shows both objects held through it; with the slots
zeroed the `seq` buffer is gone at the next collection and `res` at the 28th,
once holder 3 below lets go, `raw/tl-gcry-unpin.txt`). So three things hold
dead objects through the timed run:

1. **`0x40(%rsp)` of `Benchmark::run` holds `res`** (6.1 MB) at every
   collection from its allocation (between collections 2 and 3) to the
   process's last, the 68th, the explicit post-run `GC.collect`s included.
   From collection 28 on it is the only word on the stack that points into
   the block.
2. **`0x70(%rsp)` holds `seq`**, the `IO::Memory` the THREE section was copied
   into, and through it its 4 194 312-byte buffer: `used` at every
   collection to the end, with no stack word into the buffer itself.
3. **`Benchmark::run`'s callee-saved `%rbx`, `%r14`, `%rbp`** still hold
   `res + 12`, `res` and `res + 0x5d147c` when it calls `sort_by_freq`, and
   every callee's prologue saves them: `sort_by_freq`'s pushes put them at
   `sp+0x168` / `+0x180` / `+0x190`, `frecuency`'s at `sp+0x8` / `+0x20` /
   `+0x30` (both prologues are `push %rbp, %r15, %r14, %r13, %r12, %rbx`).
   Those are the hits in `sort_by_freq` and `frecuency` at collection 6;
   `%r14`'s copy is still there at 17 and gone by 28, when the `find_seq`
   loop has reused the registers.

The 8 MiB Fasta buffer is released by collection 4; the other large blocks are
the live `@seq` and the hash tables.

## Boehm keeps the same objects (`raw/tl-boehm-2.txt`)

The Boehm build inlines the same code with different slot numbers
(`raw/disasm-boehm-knuckeotide.txt`): `res` spilled at `0x70(%rsp)`
(`87024`), `res + 12` at `0x20(%rsp)`, `seq` at `0x60(%rsp)` (`86ffb`), and
`res` / `res + 12` / line pointer in `%r14` / `%rbx` / `%rbp` again.
`GC_size(res)` = 6 100 096, `GC_size` of the `seq` buffer 4 194 320. At every
`GC_finish_collection` from the timed run's first (#8) to the last (#77):

- `GC_is_marked(res)` = 1 and `GC_is_marked(seq buffer)` = 1;
- `0x70(%rsp)` of `Benchmark::run` points at `res`, the only stack word from
  collection 32 on;
- `sort_by_freq` `sp+0x168` / `+0x180` / `+0x190` and `frecuency` `sp+0x8` /
  `+0x20` / `+0x30` hold the same three values at #9, `frecuency`'s `%r14`
  copy is there at #20 and gone by #32.

An earlier run (`raw/tl-boehm-1.txt`, without `SEQ_PC`) read the same for
`res` through the last of its 84 collections. Holder for holder, collection phase for
collection phase, the two builds keep the same things.

### Boehm's stack clearing ran, and could not reach them

`raw/boehm-clear-stack-count.txt`: in one Knuckeotide run (77 collections)
Boehm called `GC_clear_stack` 145 244 times and `GC_clear_stack_inner`
111 720 times (bdwgc 8.2.8 `misc.c`, `THREADS`: every call zeroes a 256-word
`dummy` array below its own frame, and every 13th recurses through
`GC_clear_stack_inner` to clear `BIG_CLEAR_SIZE` = 2048 words below the SP —
111 720 / 10 levels ≈ 145 244 / 13). The holder runs have the same clearing
active, and `res` stays marked through every collection in them.
`GC_clear_stack` only writes below the current SP, by design: above it
are live frames. Holders 1 and 2 are slots of a live frame above every SP of
the run, and holder 3 is register state that callees save and restore.

gcry has both of Boehm's mechanisms: the allocation-path wipe
(`GCRY_CLEAR_STACK=1`, `src/gcry/stack_scrub.cr` `maybe_clear_stack_on_alloc`,
opt-in because it takes every allocation off the fast path) and a default
16 KiB scrub below the SP at every collection's entry and exit
(`collect_scrub`). With `GCRY_CLEAR_STACK=1 GCRY_CLEAR_STACK_EVERY=1
GCRY_CLEAR_STACK_BYTES=16384` (every allocation wipes 16 KiB) the holders are
the same frames, offsets and collections as without it through collection
28, where the gdb run timed out (`raw/tl-gcry-clearstack.txt`).

**No sound lever exists in the collector.** A word in a live frame or a
callee-saved register is a root to any conservative scan; telling a dead slot
from a live one takes the compiler's liveness. gcry's stack maps are a
research spike, off by default, whose exclusive mode replaces the
conservative scan with incomplete compiler data (`docs/STACK_MAPS.md`,
`src/gcry.cr`). Zeroing the slots, as the counterfactual does, is sound only
because a human read the disassembly.

## What the pin costs each collector (`raw/pooled.md`)

Five interleaved sessions, 11–21 reps each, pooled (`pool.py`); "× Boehm" is
against the pooled Boehm median, 39.8 MB.

| arm | runs | peak MB, median [IQR] | × Boehm |
|---|---:|---:|---:|
| Boehm (pins `res` and `seq`) | 75 | 39.8 [39.5, 47.1] | 1.00× |
| Boehm, slots zeroed | 53 | 29.0 [28.6, 31.8] | 0.73× |
| gcry 0.38.0 (pins both) | 75 | 68.5 [66.5, 72.9] | 1.72× |
| gcry 0.38.0, slots zeroed | 64 | 58.1 [48.7, 59.2] | 1.46× |
| gcry 0.37.0 | 32 | 58.4 [55.3, 59.1] | 1.47× |
| gcry 0.38.0, `GCRY_THRESHOLD=8388608` (pins both) | 32 | 48.9 [43.8, 49.7] | 1.23× |
| gcry 0.38.0, `GCRY_THRESHOLD_PACE=100` (pins both) | 32 | 56.4 [55.4, 56.6] | 1.42× |

Paired per rep within a session, peak:

| | runs | Δ MB, median [IQR] | Δ % |
|---|---:|---:|---:|
| gcry pinned − gcry zeroed | 64 | **+10.8** [+8.1, +18.0] | +18.7% [+13.6, +33.8] |
| Boehm pinned − Boehm zeroed | 53 | **+11.0** [+7.5, +18.5] | +38.3% [+23.7, +64.7] |
| gcry − Boehm, both pinned | 75 | +22.8 [+16.1, +29.0] | +52.3% |
| gcry − Boehm, both zeroed | 53 | +26.4 [+17.4, +30.1] | +83.8% |
| gcry 0.37.0 − gcry 0.38.0 zeroed | 32 | +0.8 [−2.1, +5.1] | +1.4% [−3.6, +9.5] |
| gcry 0.38.0 − gcry 0.37.0 | 32 | +10.1 [+2.0, +14.4] | +16.6% [+3.7, +24.4] |
| gcry `THRESHOLD=8 MiB` − Boehm, both pinned | 32 | +3.4 [−3.2, +6.2] | +7.9% [−6.8, +14.5] |

- **The pin costs both collectors the same**, about the 10.3 MB the two
  objects hold. It is not what separates them: gcry is 23 MB over Boehm
  when both pin and 26 MB over when neither does.
- **0.37.0 is 0.38.0 without the pin.** On 0.37.0's layout
  (`raw/tl-gcry037.txt`) no slot of `Benchmark::run` holds `res`; holder 3
  (the saved registers in `sort_by_freq` and `frecuency`) keeps it to
  collection 17 and both blocks are freed there. Its peak is the zeroed
  0.38.0's within the spread. So 0.37.0 pinned *less* than Boehm does, and
  0.38.0's +20% on this row is the pin Boehm's build has.
- Splitting the zeroing (`raw/ab-unpin-split.json`, one session, 11 reps):
  gcry with only `res`'s slots zeroed reads 57.8 MB and with only `seq`'s
  67.3 (69.8 with neither, that session); Boehm reads 43.2 for either alone
  against 39.6 for neither that session and 29.0 pooled for both — its peak
  is not monotone in the bytes it pins. Boehm's peak is multimodal here:
  its runs fall at 39–40, 43–47 or 57 MB, and the session medians are 39.6,
  39.7, 39.7, 46.8 and 46.9 MB. That is the "stale-slot lottery" the 0.37
  findings saw, but which slots hold the dead objects is code layout, fixed
  per binary (two gdb runs of the Boehm build, 84 and 77 collections, show
  the same holders), so the spread is where Boehm's collections and heap
  growth happen to fall [INFERENCE: not traced further; ASLR changing which
  words look like pointers to Boehm's blacklisting is one candidate].
- Wall time is level across the 0.38.0 arms (0.679–0.686 s); 0.37.0 is
  0.714 s, the occupancy claim's gain.

## So the gap is the schedule

With both objects pinned, a fixed 8 MiB threshold puts gcry at 1.23× pooled
and +3.4 MB [−3.2, +6.2] paired against Boehm; pacing off, 1.42×. What sizes
Knuckeotide's peak is what `../2026-10-17-knuckeotide-rss/` found on 0.37: one
paced cycle at up to 300% of the live set during the 18-letter table's
rehash, and emptied 16-byte chunks kept warm after the program moves to
32-byte strings (`GCRY_EMPTY_CHUNK_WARM_RETAIN=0`: 65.6 MB pinned, 47.5
zeroed, 11 reps each, `raw/ab-knobs.json`). The levers measured there — the
idle-kind chunk release and the pace step limit — failed the keep rule on
the runners and are parked as patches in that directory. Nothing here
changes their case.

## Decision

No gcry change. There is no sound way for a conservative collector to drop
a dead slot of a live frame or a dead value in a callee-saved register, Boehm
does not drop them either, and gcry already has Boehm's below-SP clearing.
The documentation is corrected: Knuckeotide's 0.38.0 rise is the pin Boehm
has too, 0.37.0's layout happened to pin less, and the row's excess over
Boehm's peak is the collection schedule (README, ROADMAP, CHANGELOG).

(2026-10-22: right for the mutator's frame, incomplete for the row. gcry's
own allocation-entry frame held more of Knuckeotide's dead buffers, and
gcry now wipes that frame; see the correction at the top and
`../2026-10-22-regexdna-peak/`.)

## Not established

- Other targets. Spill slots and register allocation differ per target, so
  whether the arm64, macOS and Windows builds of each collector pin these
  objects was not examined; whether a slot survives is a property of each
  build's register allocation, which the 0.38 findings saw change with
  gcry's inlining on x86. The README, ROADMAP and CHANGELOG statements are
  scoped to Linux x86_64.
- The holder timelines come from gdb runs, whose collection count (68 for
  gcry, 77–84 for Boehm) is the schedule under ptrace; which words hold
  what at a given phase is layout and does not depend on it.
