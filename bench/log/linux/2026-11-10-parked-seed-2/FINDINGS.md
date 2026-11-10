# `make parallel-dormant`'s "parked 3812 KiB" again: the Monitor's sleep frame (regression 111)

Branch `parked2-040`, on `release-0.40.0` at `43f2c953` (`src/` as
`a5a07ffe`). `GCRY_PARALLEL_DORMANT_ALL=1 bin/parallel_dormant --ordinary
--expect-dormant` failed 2 of 2 000 local runs on the tip with CI's
signature: "seeded by stack 2 KiB, parked 3812 KiB, thread 0 KiB", live
36 MB over 7 majors, 18 MB of empty chunks all warm, "FAIL: no empty chunk
went dormant". Crystal 1.21.0, Linux x86_64, 12 vCPU.

## 1. Which slot

`instr/parked-slot-words.patch` is ParkedSeed's `chunks.patch`
(`../2026-11-03-parked-seed/instr/`) without the idle-slot watch, plus a dump
of the 80 words around each holder. `rates.sh` is ParkedSeed's with the
thread count added and every run's output kept when it fails or reports a
≥ 1 MiB parked seed (the 64 KiB rule also keeps the benign 99 KiB seed most
`threads=4` runs show, so most kept files are passes).

`runs/i1.tsv`, 8 000 runs of the instrumented tip: 3 failures, and 13 runs
in which some collection first-marked a ≥ 1 MiB block as *parked*. All 13
(`runs/i1-sysmon-*.txt`) are the same slot:

- the fiber is `SYSMON`'s main fiber (the thread whose `current_is=1`),
  scanned whole (Linux: never signalled, no SP);
- the slot is 5 280 bytes below the stack's bottom in every run;
- the block is the burst's outer-array buffer, at its last capacity
  (5 945 016 bytes, all of the burst: 53 MB live, the existing retention
  path, or let go only by the seventh collect, when the budget the sixth
  measured kept every empty warm) or the one before (3 802 600 bytes, two
  thirds of it: 36 MB live, 18 MB empty, the CI signature);
- the word's high 32 bits are the heap's, its low 32 bits 9 977 500 to
  9 998 400 at each collection: a count just under the Monitor's 10 ms
  period, which changes every pass. ParkedSeed's residual
  (`../2026-11-03-parked-seed/runs/i13-final-sysmon-2020.txt`) is the same.

`runs/i1-sysmon-5069.txt` keeps the word dump. Resolved against the binary
(PIE base from the return addresses, which all land after a `call`):

| offset from slot | word | |
|---|---|---|
| −56 | `…acc2b` | return into `Crystal::System::Thread.sleep(Time::Span)`, after `nanosleep` |
| 0 | `0x746300987ee8` | **the holder** |
| +24 | `…a9b0d` | return into `Thread.sleep(Time::Span)` |
| +72 | `…355dbb` | return into `Monitor#run_loop''` (Crystal's loop, `every` inlined) |

`Crystal::System::Thread.sleep` (frame `0x48`) copies its `Time::Span` to
`rsp+0x28`: `mov %rcx,0x28(%rsp)` (seconds, `Int64`) and
`mov %eax,0x30(%rsp)` (nanoseconds, `Int32`). The holder is `rsp+0x30`.
Bytes `0x34–0x37` of that frame are never written: the word is the
remaining sleep in nanoseconds under whatever the previous call at that
depth left in the high half.

## 2. Who writes the high half

`instr/gdb-watch-high-half.cmd`: a hardware watchpoint on those 4 bytes
under gdb (no ASLR, so the address is fixed; `runs/gdb-watch-high-half.txt`).
Each pass writes them several times: `MonitorGate.leave`'s scrub and wipe
(0), `__crystal_once` (the binary's high half), `Time::Instant#-` (a count),
`Range.new` (0), and last, just before `Thread.sleep`,
`Comparable#clamp` — `every`'s `remaining = (start + @every -
stop).clamp(Time::Span.zero..)`. Its frame (`clamp<Range(Time::Span, Nil)>`,
`0x48`, called from the same loop at the same depth as `Thread.sleep`) has
`rsp+0` exactly at the holder, and its first store is
`mov %rdi,(%rsp)`: `self`, a pointer to the `Time::Span` in the loop's frame,
i.e. an address in SYSMON's stack. Thread stacks and gcry's chunks are both
anonymous mappings in the same region, so their high 32 bits match
(`0x7463` in the failing run: stack `0x74630a1f…`, buffer `0x74630089…`).

So every 10 ms the Monitor builds, in Crystal's frames, the word
`(stack high half << 32) | remaining_ns`, an address in the heap's 4 GiB,
and sleeps on it. It names gcry's heap whenever a block lies just under
offset 10^7 (`0x989680`) of that 4 GiB window, which ASLR decides per process.
Not birth residue: regression 107's scrub (`7bfb0358`) runs once, before the
loop, and this half is rewritten by `clamp` every pass, so it never could
have reached it. It is in Crystal's frame and written by Crystal's code;
what gcry can own is the stack under `Thread.sleep` before those frames are
built.

## 3. Fix

`Thread.sleep(Time::Span)` is reopened in `monitor_gate.cr`, beside the
Monitor's other wrappers (the Monitor's `every` is its one caller in Crystal
1.21–1.22): it wipes 1 KiB below its SP, frameless (`Roots.wipe_below_sp`,
as `MonitorGate.leave` and the loop prologue do), then calls Crystal's sleep,
which is `@[NoInline]` so its frames are built after the wipe. The half
`System::Thread.sleep` does not write is then 0, and a count under 10^7 names
nothing. A Crystal without `Thread.sleep` fails to build, as for the other
wrapped methods. All platforms; once per Monitor pass. Over-retention only:
everything zeroed is below the SP.

The wrapper's own frame copies the `Span` too; at `-O0` its layout is the
old `Thread.sleep`'s (`0x28`, the `Int32` at `rsp+0x20`, `objdump` of
`bin/pd_fix`), whose word at that depth was clean in every dump. The rates
below are what says it is clean in this build.

## 4. Rates

`rates.sh`, 8 workers, under the heavy lock. Fail = the run exited 1; big =
some collection first-marked a ≥ 1 MiB block as parked (instrumented builds
only).

| round | binary | runs | failed | big parked seeds |
|---|---|---:|---:|---:|
| i1 | tip, instrumented | 8 000 | 3 | 13 (all SYSMON, slot −5 280) |
| i2 | tip + `instr/sleep-wipe.patch` (the wipe, no test hooks), instrumented | 8 000 | 0 | 0 |
| r1 | tip `pd_tip` (`a5a07ffe`) | 8 000 | **5** | — |
| r1 | **fix `2d94a233`** | 8 000 | **0** | — |
| r1 | fix, instrumented | 8 000 | 0 | 0 |

r1 interleaves the three per iteration. All 5 tip failures are CI's
signature (`runs/r1-pd_tip_*.txt`: "parked 3812 KiB, thread 0 KiB" three
times, "parked 3713/3714 KiB, thread 3 KiB" twice; live 36 MB, 18 MB warm).
Fix against tip in r1: 0 / 16 000 against 5 / 8 000, p = 0.004 (Fisher,
two-sided); over all rounds 0 / 24 000 against 8 / 16 000, p = 0.0007; big
seeds 0 / 16 000 against 13 / 8 000, p = 0.0002.

## 5. Regression 111

`process_spec/regression/111_monitor_sleep_frame_spec.cr`, each arm in its
own process, Linux only (skip marker elsewhere and without a Monitor). With
`GCRY_MONITOR_SLEEP_TEST` the Monitor writes `LOOP_MARKER` over 8 KiB below
`Thread.sleep`'s frame before each sleep, standing in for `clamp`'s residue;
the child counts words below that frame keeping the marker's high half over
another low half. Fixed arm: 0. Control (`sleep_residue_kept?`, the code
before): 3 on 1.21.0 ([INFERENCE] the `Span` copies of `Thread.sleep'`,
`''` and `System::Thread.sleep`); none would print the skip marker.

## 6. Checks on `2d94a233`

- `verify.sh` (after `rm -rf lib/ameba bin/ameba`): format, lint (264
  files, 0 failures), `spec` ×3 (307 / 330 / 307 examples), `process_spec`
  ×3 (465 / 466 / 466 examples, 2 pending each), all 0 failures.
- `make windows-typecheck`, `make darwin-typecheck`, `make
  alloc-entry-frame` (5 examples): ok.
- Crystal 1.22.2 `process_spec`: 465 examples, 0 failures, 3 pending.
- Regression 111 looped 20 times on 1.21.0 and 20 on 1.22.2: fixed 0 words
  every run, control 3 every run, no skip.
- `make parallel-dormant` once: six arms PASS.

## 7. Keep rule

The wrapper runs once per Monitor pass (1 KiB of stores every 10 ms); what
it can move is code placement. `perf-ab.yml` 42841019863: `2d94a233`
against `v0.39.0`, five runners, nine benches, 15 reps, Boehm, stats=3,
pads `p16 p64 bp16 bp64`; `keep.py` (`../2026-11-01-0.40-keep-rule/`):
45 rows, 32 ok, 12 placement, **1 flagged**: `ubuntu-latest` JsonParsePure,
time +2.1% [+1.5, +2.5], wall +0.9%, var-code 0.864 / 0.873 / 0.869 against
base-code 0.845–0.857 (`keep/keep-42841019863.txt`). The release tip's run
(42385593882) had that row ok, on a faster runner (0.53 s).

Followed as the keep rule's §2 did, on the flagged runner, 21 reps, three
JSON rows, four pads:

- 42854942802, against `v0.39.0`: JsonParsePure **ok**, +0.2%
  [−1.0, +4.0], var 0.605 / base 0.604; JsonParseSerializable and
  JsonParsePull placement (`keep/keep-42854942802.txt`).
- 42852039642, against the release tip `43f2c953` itself: all three rows
  placement, var slower unpadded (+2.1%, +5.8%, +5.8%) and `prepad16`
  inside the tip's band in each (JsonParsePure 0.675 in 0.663–0.682,
  JsonParseSerializable 0.556 in 0.550–0.576, JsonParsePull 0.542 in
  0.538–0.561) (`keep/keep-42852039642.txt`).

No row unexcused.

## Files

- `rates.sh`, `runs/{i1,i2,r1}.tsv` and `*-summary.txt`: the rounds (binary,
  index, exit code, parked KiB, threads).
- `runs/i1-sysmon-*.txt`: the 13 instrumented big-seed runs
  (`i1-sysmon-5069.txt` with the word dump); `runs/r1-pd_tip_*.txt`: the 5 tip
  failures.
- `runs/gdb-watch-high-half.txt`, `instr/gdb-*.cmd`: the watchpoint.
- `instr/parked-slot-words.patch`: the diagnostics (never committed to
  `src/`); `instr/sleep-wipe.patch`: the first form of the fix (round i2).
- `keep/`: the three `perf-ab.yml` runs, `keep.py` output and summaries.

## Commit hashes after the rebase

The hashes above are from `parked2-040` before it was rebased onto `release-0.40.0` (kept as tag `archive/parked2-040`, `de2b7528`). On `release-0.40.0`: `2d94a233` is `32b11119`, `b8fc26cf` is `2c6c442a`, `ceebebe7` is `2c208eb0`, `de2b7528` is `0e4e6d72`. The source is the same.
