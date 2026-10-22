# RegexDna's lower peak with the occupancy claim was one stale slot in gcry's own frame (2026-10-22)

Linux x86_64, 12 vCPUs (QEMU guest, shared with other agents; every timed
or traced run held `heavy.lock`), Crystal 1.21.0 (LLVM 20.1.8), `--release`.
crystal-metric built in `bench/crystal_metric` the way
`bench/run_crystal_metric_ab.sh` builds it, one binary per tree:

| binary | gcry tree | sha256 prefix |
|---|---|---|
| `cm-pre` | `d2594ff8`, the last tree before the occupancy claim | `e7be2f8a9df50515` |
| `cm-claim` | `20cbb8f2`, the claim | `6dd7dffd314b5a2a` |
| `cm-tip` | `32ce703a`, `release-0.39.0` when this started | `4b520ca4d8fad0ff` |
| `cm-proto` | `cb092ae5`, this branch's change (below) | `ce64d5823125318c` |

The question (0.39.0 open item): RegexDna's peak fell 19% with 0.38.0's
occupancy claim (270–271 MB on every tree before it, 219 MB after,
`../2026-10-21-0.38-crystal-metric/regexdna-bisect.md`), and nothing in the
claim touches what RegexDna allocates. Is it a retention or schedule
property that could lower other rows?

**Answer: neither. It is one word of stack.** Before the claim, the
out-of-line `Gcry::Heap#malloc_atomic` had a slot, `0x58(%rsp)`, that only
its hit path writes. At three collections of RegexDna's setup that slot held
the dead `Fasta` object, put there long before by `GC.realloc`'s push of a
callee-saved register, and the conservative scan kept the `Fasta`'s 64 MiB
output buffer alive through them, exactly while the setup's two other 60 MB
strings were being built. The claim changed the inlining
(`Heap#malloc_atomic` folded into `GC.malloc_atomic`), the frame layout moved,
and the slot went away. The schedule is the same; the timed run's own peak
is the same on both trees (219 MB); what changed is that the setup's peak,
270 MB, no longer exists, so the process peak is now the timed run's.

That is the same class as the allocation-entry frame fix (`c2dd2226`,
`../2026-10-20-alloc-entry-frame/`): the frame live across an
allocation-triggered collection holds slots the slow path never writes. As a
lever: hiding every such word from the scan on 0.39.0 moves only Knuckeotide
(about −23% under gdb), nothing else. This branch makes it a default: the
slow path leaves the entry frame by a tail call and zeroes the stack below
it, so the frames a collection runs on hold only what they write
(`Heap#allocate_entry`, regression 86). Knuckeotide's peak −12% locally;
on five runners Knuckeotide falls from 1.44–1.78× to 1.28–1.63× Boehm's peak with no row slower beyond its spread (section 4).

## 1. Reproduction

Peaks, `/usr/bin/time` (`raw/time.txt`), two runs each, with and without
`GCRY_TRACE`: `cm-pre` 277 144–277 296 kB, `cm-claim` 223 676–224 092 kB.
Both trees run 25 collections, and up to the 11th they are the same
collection for collection (`raw/trace-{pre,claim}-1.ndjson`,
`GCRY_TRACE=1`, `collect_end`: heap size / next threshold / pace, MiB):

| collection | 10 | 11 | 12 | 13 | 14 | 15 | 16 |
|---|---|---|---|---|---|---|---|
| pre | 85 / 16 / 100 | 143 / 31 / 100 | **169** / 35 / 100 | 177 / 39 / 100 | **241** / 47 / 100 | 183 / 45 / 100 | 124 / 29 / 100 |
| claim | 85 / 16 / 100 | 143 / 31 / 100 | **105** / 56 / 300 | 191 / 32 / 106 | 159 / 31 / 100 | 183 / 45 / 100 | 124 / 29 / 100 |

At the 12th collection the claim tree is 64 MiB smaller. From the 15th on the
two are identical again, the timed run's last collections included.

Where the peak is (`rss_timeline.py`: `VmRSS` polled every 0.5 ms on the
trace's clock):

| tree | setup peak (to collection 15) | timed run peak | process peak |
|---|---:|---:|---:|
| pre | **270.3 MiB**, at 746 ms, between collections 14 and 15 | 219.2 MiB | 270.3 MiB |
| claim | 210.7 MiB | **219.0 MiB**, in `gsub` | 219.0 MiB |

The setup (`RegexDna#initialize`) runs `Fasta.new(6000000)`, whose
`IO::Memory` grows to a 64 MiB buffer; takes `res = f.@result.to_s` (58 MiB);
copies it line by line into a second `IO::Memory` (64 MiB) and takes
`@seq = seq.to_s` (57 MiB). After `to_s` the `Fasta` and its buffer are dead.
On `pre` the 64 MiB buffer is still mapped and marked when `@seq` is
allocated; on `claim` it was swept at collection 12.

## 2. The holder

`holders2.py` (gdb): at every collection entry, every word of the collecting
thread's stack and registers from which the 64 MiB block is reachable in at
most three hops (each hop: one of the first 16 words of the object pointed
at). `raw/h2-pre.txt`, `raw/h2-claim.txt`, same environment:

- Both trees have the same stale words in `Benchmark::run`'s frame
  (`sp+0x30`/`+0x38` → `0x7ffff7c3a6e0` → the `IO::Memory` → the buffer, and
  `sp+0x3f60`/`+0x3f80` → … three hops). These do not hold it on either
  tree: the claim tree sweeps the buffer with both still present, so
  the objects they point at are not allocated any more.
- `0x7ffff7c3a700` is the `Fasta` (it is `self` in `make_random_fasta`'s
  frame at collections 9–10). On `pre`, at collections 12, 13 and 14, one
  word points at it: `0x58(%rsp)` of `Gcry::Heap#malloc_atomic`, frame 4,
  the out-of-line allocator `String.new` calls for `line.chomp`. On `claim`
  no word does after collection 11.

`raw/disasm-pre-heap-malloc_atomic.txt`: that function is
`push ×6; sub $0x78,%rsp`, and `0x58(%rsp)` is written at `80ad5` and read at
`80a42`, both on the hit path. The slow path's `call allocate` (`8075a`)
comes before either, so on the way to a collection the slot holds whatever
the stack had there.

**Counterfactual** (`zero_slot.py`, no other change): zeroing that one word
at the 12th collection's entry, before the mark, sweeps the buffer at the
12th collection, as on the claim tree (`raw/zs-pre-{ctl,zero}.ndjson`, heap
MiB from collection 9):

| arm | 9 | 10 | 11 | 12 | 13 | 14 |
|---|---|---|---|---|---|---|
| pre, control | 85 | 85 | 143 | 169 | 177 | 241 |
| pre, slot zeroed at 12 | 85 | 85 | 143 | **105** | 116 | 180 |
| claim | 85 | 85 | 143 | 105 | 191 | 159 |

and `gcry_frames.py` (below) hiding every non-push word of gcry's frames on
`pre` takes the run's `VmHWM` from 276 912 kB to 224 164 kB, the claim
tree's number (`raw/gf-pre-{ctl,hide}.txt`).

**Who wrote it** (`who_wrote.py`, a hardware watchpoint on the slot,
`raw/who-wrote-pre.txt`): `push %rbp` at the entry of `GC.realloc_impl`,
called from `IO::Memory#resize_to_capacity` ← `make_random_fasta`. `%rbp`
held `self`, the `Fasta`: a callee-saved register of the mutator, saved by
gcry's realloc prologue, deep in the Fasta phase. Seconds later, at the same
address, `Heap#malloc_atomic`'s frame (called from shallower code) has its
unwritten `0x58` slot.

So the 19% is a frame-layout lottery inside gcry, of the class `c2dd2226`
fixed for `check_fork_poison!`'s buffer: the frame live across an
allocation-triggered collection holds slots the slow path does not write.
The claim's semantics — occupancy, claims, release — play no part, the
schedule only follows the live set (the pace 300% at the claim tree's
12th collection is the threshold reacting to 64 MiB less live), and Boehm's
`GC_clear_stack`-style clearing below the SP could not have reached it (the
slot is above the SP, in a live frame): `GCRY_CLEAR_STACK=1` leaves both
trees at 270–271 MB (`raw/ab-clearstack-runs.json`, 3 reps; it also takes
the hit path away, 10× the wall time, and moves the frames).

## 3. Is it a lever for other rows?

`gcry_frames.py`: at every collection entry, every word in gcry's own frames
above the collector (the allocation entry and the slow path: everything from
`run_collection` up to the first non-gcry frame) that is not one of the
prologue's callee-saved pushes and holds an address in an anonymous mapping
is zeroed for the mark and restored before those frames run again: the
upper bound of "no stale word in gcry's frames". The control arm stops at the
same two points per collection and changes nothing (an earlier control that
stopped once fewer per collection collected on another schedule: the pace
reads pause time). The bench's output is unchanged in the hidden arm.
`VmHWM`, MiB, on `cm-tip`, 3 runs each (`raw/sweep-tip-matched.txt`):

| row | control | hidden | collections ctl / hidden |
|---|---|---|---|
| RegexDna | 218.7 | 218.7 | 25 / 25 |
| Revcomp | 526.3 | 526.3 | 28 / 28 |
| JsonParsePure | 551.0 | 555.6 | 16 / 15–17 |
| **Knuckeotide** | **71.5** [55.0–73.3] | **52.3** [50.7–57.2] | 65–70 / 70–71 |
| Binarytrees | 34.5 | 36.7 | 234–257 |
| JsonParsePull | 407.8 | 408.8 | 14–16 |
| JsonParseSerializable | 408.0 | 407.9 | 16–18 |
| JsonGenerate | 770.5 | 770.4 | 15–16 |
| Primes | 612.9 | 618.9 | 9–10 |

Only Knuckeotide moves. Split by frame, 6 runs each (`raw/k-split.txt`):
hiding the allocation entry's words (`GC::malloc_atomic`, `GC::malloc`)
alone, 67.8 → 51.9 MiB median, collections 65–68 → 69–70; hiding the
`Gcry::Heap#…` frames' words alone, 59.6 → 59.4 (those words are the
thread's TLS block, not heap). On 0.39.0's layout the entry
`GC::malloc_atomic` is `push ×6; sub $0x78,%rsp`, and before its slow path's
`call allocate` (`1b475`) it writes one of its 15 local words, `0x70` (the
TLS lookup's result); the other 14 are the hit path's
(`raw/disasm-tip-gc-malloc_atomic.txt`; regression 79 counts 13 pattern
words surviving there). In Knuckeotide's timed run its `0x30` and `0x60`
slots hold the user pointers of 786 KiB hash-entry buffers at collections
51 and 60, unmapped by collections 54 and 63 once the slots have moved on
(`raw/holders-tip-knuckeotide.txt`, `holders_gcry.py`), and `0x8`/`0x10`
the last block a hit handed out (`raw/gf-tip-knuckeotide-ctl-verbose.txt`).

JsonParsePure, Revcomp and RegexDna on 0.39.0 hold nothing through gcry's
frames: their peaks are their live sets and the schedule, and this is no
lever for them.

## 4. The change: no frame the hit path wrote under a collection

`Heap#malloc` and `Heap#malloc_atomic` now end the slow path with
`allocate_entry(…)` in tail position. `allocate_entry` (`@[NoInline]`) is
`Roots.wipe_below_sp` and a tail call to `allocate_traced` (`@[NoInline]`:
`allocate` and the `Invariant`/`Trace` hooks the slow path ran before).
`wipe_below_sp` is a loop of stores in inline asm over the 1 KiB below the
SP, on scratch registers only (`r11`; `x9`/`x10`), so the arguments pass
through and `allocate_entry` needs no frame. In the release build
(`raw/disasm-proto-gc-malloc_atomic.txt`): `GC::malloc_atomic` ends its
slow path with `add $0x88,%rsp; pop ×6; jmp allocate_entry`; `Heap#malloc`
(which `GC::malloc` reaches by `jmp`) the same; `allocate_entry` is the
eight-instruction loop and `jmp allocate_traced`, no prologue. So by the time
anything collects, the entry's frame is gone, and every frame from
`allocate_traced` down to `run_collection` — whose own entry scrub covers
everything below it — is built over zeros (168 bytes deep on this layout).

Sound: the entry's frame is popped before the wipe, its callee-saved pushes
restored into the registers they came from, and those are pushed again by
`allocate_traced`; nothing below the SP is live in a function that keeps
nothing of its own on the stack; a signal landing mid-wipe builds its frame
below the SP and is done before the wipe resumes over it. Windows does
nothing in the wipe (stack growth through `PAGE_GUARD`, as
`OS.clear_dead_stack` handles), so it gets the tail calls only. The review
(agent `WipeReview`, release builds of regression 86 for x86-64 Linux,
aarch64 Linux, aarch64 and x86-64 Darwin, all disassembled) found the tail
calls on every target. On Linux `allocate_entry` has no prologue; on both
Darwin targets LLVM keeps the frame-pointer convention and pushes a frame
record around the loop alone (`push %rbp` / `stp x29, x30, [sp, #-16]!`),
popped before the tail branch, so there the wipe starts 8 or 16 bytes lower
and skips only the saved frame pointer and return address. A debug build (a
`-Dgc_none` `samples/hello.cr`, disassembled) makes ordinary calls, and calls
the wipe as a leaf with no frame that zeroes below its own return address.
Where the entry is inlined into its caller, the caller's frame is the
caller's, as under any conservative collector. `GCRY_SLOW_ENTRY_WIPE=0`
turns the wipe off (research, the control arm).

**Bound** (branch `wipe-clamp-039`, after review). The first version stored
into the 1 KiB below the SP without the stack's bounds, so a thread or fiber
with less than 1 KiB above its guard page would have overflowed on a slow path
that did not go that deep itself. The bound needs no allocation and no
syscall: `Fiber.current?` is `Thread.current?` — one thread-local load, which
LLVM emits as a call to a five-instruction accessor (`%fs` plus an offset) —
and the nilable `current_fiber?`, and `Fiber#@stack` holds the bounds Crystal
computed when the fiber was made (the mapped span, guard page lowest, for a
spawned fiber; `pthread_getattr_np`'s for a thread's main fiber). These are
the bounds `clear_stack_body` already takes for the collector's scrub.
`Roots.wipe_floor` clamps the wipe to the page above the stack's lowest,
rounded so the 16-byte loop ends at the SP, and skips it when there is no
current fiber (a thread whose `Thread` is not set yet; `Fiber.current` without
`?` would make one, which allocates) or the SP is outside the fiber's stack
(a signal on an alternate stack, a fiber switch mid-swap). The accessor call
gives `allocate_entry` a frame (six pushes and the accessor's 8-byte slot,
every word written, popped before the tail `jmp`); the wipe starts below it.
Regression 86 still reads 0 stale words with it (control 2). Its new
guard-page arms: a child fiber recurses until 340–640 bytes are left above
its guard page and wipes there. The bounded wipe lives, with its floor
clamped to the guard's top (not skipped); the first version's unbounded loop
dies with "Stack overflow".

Cost is on the slow path only — a cursor refill, a large block, a
collection — 64 iterations of two stores. The hit path's code changes
because its arguments must reach the tail call: it now spills `self` and the
size around the TLS lookup, two stores and two loads
(`raw/disasm-proto-gc-malloc_atomic.txt` against the tip's).

**Regression 86** (`process_spec/regression/86_alloc_slow_path_clean_frames_spec.cr`,
run by `make alloc-entry-frame`, `--release`, in CI's x86-64 test job): a
deeper call fills 8 KiB of stack with a pattern, an allocation at the same
depth triggers a collection, and the hook counts pattern words left between
the allocating call and `collect_entry_sp`. Tree before: **13** (fails).
With the change: control arm (`slow_entry_wipe = false`, the tail calls
alone) **2**, fixed arm **0** (passes). A debug build, Windows, and
architectures without the asm print `stale86: … skipped`.

### Local A/B (`ab.py`, 11 interleaved reps, `raw/ab-proto11-runs.json`)

`cm-proto` against `cm-tip`, paired per rep, median [IQR] (`paired.py`):

| row | tip | proto | wall Δ | peak Δ |
|---|---|---|---:|---:|
| Binarytrees | 0.554 s, 38 MB | 0.565 s, 37 MB | +3.0% [−1.8, +5.9] | −0.3% |
| Brainfuck (allocates nothing) | 2.809 s | 2.845 s | +2.3% [−0.3, +3.1] | 0 |
| Brainfuck2 | 1.245 s | 1.267 s | −0.7% [−1.6, +4.7] | 0 |
| **Knuckeotide** | 0.796 s, **64 MB** | 0.775 s, **56 MB** | −1.6% [−4.0, −0.4] | −4.9% [−22.7, −0.7] |
| RegexDna | 2.644 s, 219 MB | 2.642 s, 219 MB | −0.5% | +0.1% |
| Revcomp | 2.168 s, 526 MB | 2.207 s, 526 MB | +1.7% [−0.0, +3.9] | 0 |
| Threadring | 0.437 s | 0.441 s | +0.7% | 0 |
| Matmul | 0.391 s | 0.392 s | +0.3% | −0.4% |
| JsonGenerate | 1.674 s, 771 MB | 1.641 s, 771 MB | −2.9% [−3.4, −0.7] | 0 |
| JsonParseSerializable | 0.948 s, 409 MB | 0.958 s, 409 MB | +0.6% | −0.1% |
| JsonParsePull | 0.937 s, 409 MB | 0.924 s, 410 MB | +0.7% | +0.3% |
| Primes | 0.753 s, 619 MB | 0.752 s, 619 MB | −0.2% | 0 |
| JsonParsePure | 0.949 s, 551 MB | 0.939 s, 554 MB | +1.5% [−1.1, +2.7] | −0.5% |

This host's noise floor is Brainfuck's +2.3%: no wall delta here is outside
it. An earlier 5-rep session with the wipe-off arm
(`raw/ab-proto5-runs.json`): Knuckeotide tip 71 MB, proto 58 MB, proto with
`GCRY_SLOW_ENTRY_WIPE=0` 69 MB — the wipe, not the tail calls alone, is most
of the gain, as regression 86's 2 words suggest.

### Five runners: the keep rule holds

`Perf A/B` [39738092074](https://github.com/sdogruyol/gcry/actions/runs/39738092074):
var `cb092ae5` (this change), base `32ce703aac1c10baeddff2e744a3702c1b4089c6`
(`release-0.39.0`), 15 interleaved reps, ten rows, Boehm arm, `stats=3`,
extra arm `GCRY_SLOW_ENTRY_WIPE=0` (`var_env`), all five runners green
(`perf-<runner>/summary.md`). % of Boehm's speed / × Boehm's peak, median
[IQR], base → var:

| runner | Knuckeotide peak | wipe off | Binarytrees speed | slower beyond the IQR |
|---|---|---|---|---|
| ubuntu-latest | 1.53× [1.31, 1.70] → **1.31×** [1.27, 1.46] | 1.50× | 90% → 92% | none |
| ubuntu-24.04-arm | 1.44× [1.30, 1.48] → **1.28×** [1.23, 1.34] | 1.30× | 102% → 102% | none |
| macos-latest | 1.58× [1.54, 1.58] → **1.32×** [1.31, 1.32] | 1.32× | 94% → 94% | none |
| macos-15-intel | 1.78× [1.63, 1.83] → **1.56×** [1.53, 1.56] | 1.56× | 146% → 148% | none |
| windows-latest | 1.73× → 1.63× (no wipe there) | 1.71× | 123% → 118% (IQRs overlap) | none |

No row is slower beyond its spread on any runner (JsonGenerate on
ubuntu-latest 89% → 87%, IQRs [87, 90] and [87, 88]; Revcomp is faster on
macos-15-intel, 90% → 96%). Peaks are level or lower everywhere except
JsonGenerate on macos-latest, 0.64× [0.64, 0.64] → 0.71× [0.64, 0.77]; the
wipe-off arm reads 0.77× there, so it is the layout of the tail calls rather
than the wipe, and it stays far under the 1.1× budget. Not attributed. On
Darwin the wipe-off arm matches var on Knuckeotide (1.32×, 1.56×): there the
tail calls alone remove the holder. Every row except Knuckeotide stays within
1.1× Boehm's peak; Knuckeotide, the budget's one exception, falls 0.10–0.26×
of Boehm on every runner. **Keep rule: holds.**

## Tools (this directory)

- `rss_timeline.py BIN OUT`: runs one bench with `GCRY_TRACE=1` and
  `GCRY_TRACE_LARGE=1`, polls `VmRSS` every 0.5 ms on the trace's clock, and
  places the peak between collections.
- `holders2.py` (gdb, `BIN TRACE PAYLOAD COLLS`): the stack and register
  words from which one large block is reachable in ≤ 3 hops, per frame and
  slot, at chosen collections. `../2026-10-21-knuckeotide-pin/holders_gcry.py`
  is the one-hop version.
- `zero_slot.py` (gdb, `BIN AT SLOTS`): zero stack words at one collection's
  entry. The stack moves with the environment's size: find the slot with the
  same `ENVS` first.
- `gcry_frames.py` (gdb): the upper bound of section 3; `gf_sweep.sh`,
  `gf_only.sh` drive it.
- `who_wrote.py` (gdb, `SLOT VALUE`): a conditional hardware watchpoint on a
  stack word; the writer that leaves `VALUE` there, with its backtrace.
- `paired.py runs.json BASE VAR`: paired per-rep deltas from `ab.py`'s
  `runs.json` (`../2026-10-14-rss-budget-recheck/ab.py`, which reads a
  wrong-checksum run as failed: RegexDna, Knuckeotide, Revcomp and the JSON
  rows print `err result=` on this host in every arm, Boehm's included, the
  same value in each, so the timings stand).
