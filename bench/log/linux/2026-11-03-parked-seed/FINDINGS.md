# `make parallel-dormant`: "seeded by … parked 3714 KiB" — three unwritten stack slots (regression 104)

Branch `parked-seed-040`, on `release-0.40.0` at `20c7af11` (`src/` identical to
`fb735222`). CI run 41391239317, job 125102880486: the
`GCRY_PARALLEL_DORMANT_ALL=1 … --ordinary --expect-dormant` step reported
"seeded by stack 2 KiB, parked 3714 KiB, thread 3 KiB", live 36 MB over 7
majors, "FAIL: no empty chunk went dormant".

## 1. Rates, and `21462240`

`rates.sh`: the failing arm, interleaved per iteration across binaries, 4–6
workers, under the heavy lock (`runs/r*.tsv`, one line per run: binary,
index, exit code, parked KiB). Failures classed by the seed line: *parked*
(parked ≥ 3000 KiB) or *stack* (stack ≥ 3000 KiB).

| round | binary | failed | parked | stack |
|---|---|---|---|---|
| r1+r2 | tip `fb735222` | 22 / 3 500 | 13 | 9 |
| r1+r2 | base `96956b42` (before `21462240`) | 15 / 3 500 | 13 | 2 |
| r1+r2 | tip, `pthread_scan_running_sp_clamp = false` | 15 / 3 500 | 12 | 3 |
| r2 | idle-thread fix only | 6 / 2 500 | 0 | 6 |
| r3 | tip | 21 / 4 000 | 13 | 8 |
| r3 | idle fix + register buffer clear | 5 / 4 000 | 2 | 3 |
| r4 | idle fix + register buffer clear | 9 / 5 000 | 4 | 5 |
| r4 | + pre-mutator-scan scrub | 4 / 5 000 | 4 | 0 |
| r5 | tip | 25 / 5 000 | 17 | 8 |
| r5 | **final (this branch)** | **5 / 5 000** | 5 | 0 |

Tip against base, and against the clamp turned off: p = 0.32 each (Fisher,
two-sided). **Not `21462240`.** Its code also runs after the mutator scan
(`scan_other_thread_stacks`) and seeds as *thread*, never *parked*. Tip
against final in r5: p = 0.0003. Every failure in every arm names the same
block: the burst's outer-array buffer at its second-to-last capacity (3 802 600
bytes; grown in place from 1.24 MB, then moved), so the 36 MB is the ~475 000
inner arrays it points at.

## 2. What held it

Diagnostics in `instr/` (applied to `src/` for a build, never committed):
`parked-seed.patch` dumps the fiber and thread whose scan first marked a
≥ 1 MiB block and the slots naming it; `stack-seed.patch` the same for the
collecting thread's own scan; `chunks.patch` lists every chunk containing
the holder value; `stack-frames.patch` the code addresses and words around
the slot; `parallel_dormant_instr.cr` logs the burst buffer's moves.

### Parked: the idle collector's loop frame (the CI signature)

`runs/i1-parked-421.txt`: the fiber is `gc-idle`'s main fiber, running,
scanned from `IdleRelease.parked_sp` less the slack; the holder is
`parked_sp + 32`, 4 984 bytes below the stack top, in every failing run
(14 of 14). Disassembly of `IdleRelease.loop_forever` (frame `0xb8`): that
is `rsp + 0x18`, a slot whose eight bytes only a `Bool` local writes one of
(`0x1b`). `runs/i4-parked-watch-514.txt`: the slot holds the same value at
every collection from the first, before the burst buffer reached it; the
value is a heap-region address, and only the large chunk contains it
(`runs/i7-parked-chunks-1415.txt`), so it names no live object. It is
residue at that depth from the thread's birth (`Thread#start` allocates the
main `Fiber` just before the block runs), in a frame that never returns and
is read at every collection. It keeps the burst whenever the buffer is
mapped over that address.

### Stack: the mutator scan's own frames

`runs/i7-stack-chunks-484.txt`, `runs/i8-stack-frames-429.txt`: the
collector's own stack, 1 200 (or 1 184) bytes below `collect_entry_sp`, in
the frames `scan_mutator_stack` builds, with a value that moves by ~140 per
collection. It is at that depth in every build measured, including one
whose register buffer was elsewhere (with the buffer cleared it stayed,
5 / 5 000, r4). The entry scrub zeroes last cycle's residue; this is what
this cycle's earlier phases (clear, fiber, thread and static scans, timers)
leave at the depth the scan's frames then take without writing. A scrub
just before the scan: 0 / 5 000.

### The register buffer (found on the way)

`Roots.capture_registers`: the mutator scan, `each_spilled_register` and the
Monitor's spill scan all 256 bytes of a buffer `setjmp` writes 80 of on
x86_64 glibc (and the frame pointer into the last word). Regression 104's
control arm reads all 21 other words back as registers. Whether it held the
burst in any run is not established; it is a real unwritten-word root on
its own.

### What is left: the monitor's frames

`runs/i13-final-sysmon-2020.txt`: all 4 failures of 6 000 on the final
tree (instrumented) are SYSMON's main fiber, scanned whole (signal-exempt,
no SP). The holder words' low 32 bits are 9 995 311–9 998 400 (≈ 10 ms in
ns) and their high 32 bits the heap's: a nanosecond count beside four
stale bytes, [INFERENCE] a `Time::Span`'s `Int32` and its padding. That is
Crystal's frame, not gcry's; left open (ROADMAP).

## 3. Fix

- `IdleRelease.ensure_started`: the thread's block scrubs its stack below
  itself (from the pagemap low-water mark, else 64 KiB) and wipes the band
  frameless, then calls `loop_forever` (`@[NoInline]`). Control:
  `IdleRelease.birth_residue_kept`.
- `Heap#pre_mutator_scan_scrub` before `scan_mutator_stack`: the entry
  scrub and band wipe again, not counted in `collect_scrub_runs`. Control:
  `Heap#mutator_scan_scrub = false`.
- `Roots.capture_registers` clears the buffer before `setjmp` (Windows
  already cleared it). Control: `Roots.register_residue_kept`.

All three zero memory that is dead (below the SP) or that nothing writes
after the clear, so nothing live is read less: over-retention only.

## 4. Regression 104

`process_spec/regression/104_unwritten_root_words_spec.cr`, each arm in its
own process, Linux only (skip marker elsewhere): idle loop frame
(fixed frees / control keeps / unplanted frees a block planted by the thread
at birth), mutator-scan frames (same, planted from the `MarkStart` hook),
register buffer (0 pattern words yielded fixed, 21 control). Local: 16
examples, 0 failures, three runs.

## 5. Not done here

Checks on the pushed tree (`verify.sh`, typechecks, 1.22.2 `process_spec`,
`make parallel-dormant` looped, `make alloc-entry-frame`) and the keep rule
were not run in this session; see the report.

## Files

- `rates.sh`, `runs/r1–r5`, `runs/i*.tsv`: the rate rounds.
- `runs/*.txt`: the failing outputs quoted above;
  `runs/local-tip-fail-143.txt` is the original local reproduction.
- `instr/`: the diagnostics.
