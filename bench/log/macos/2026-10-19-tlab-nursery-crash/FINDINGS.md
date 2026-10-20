# `make nursery-tlab-smoke` SIGSEGV in `scan_all_fiber_roots` on macOS (2026-10-19)

CI run [38975094005](https://github.com/sdogruyol/gcry/actions/runs/38975094005),
job 117222511786 `test (darwin arm64, gates)` (PR #54 on base `233b3ad6` =
v0.36.0 code), `make nursery-tlab-smoke` — `GCRY_BITMAP_ALLOC=0
bin/nursery_tlab_smoke` built `-Dgc_none -Dgcry_block_headers`:

    claim_probe: free_after_minor=true free_after_major=true minors=12 tlab_hits=32 tlab_refills=10
    PASS minor left the FREE node on the stack FREE
    PASS major left the FREE node on the stack FREE
    Invalid memory access (signal 11) at address 0x6c696665725f6271
    *Gcry::Heap#scan_all_fiber_roots:Nil +340 (2 times)
    *Gcry::Heap#run_collection_body … ← collect:scan_stack ← released_chunk_probe ← __crystal_main

(`ci-history/job117222511786-excerpt.log`.)

**Verdict: a gcry bug, reproduced, root-caused and fixed.** A collection
asked for with `scan_stack: false` skipped every stack — the caller's, every
parked fiber's, and every other thread's, with their registers and `Thread`
objects — where the caller can only speak for its own. The idle thread gcry
starts at the end of the first collection was still in its birth when the
smoke's first `minor_collect(scan_stack: false)` ran, holding its new main
`Fiber` in its own frame alone; the minor freed the fiber, the thread's push
published the freed block on Crystal's fiber list, the `String` the smoke
printed next was built in it, and the next fiber walk read that string's
bytes as `Fiber#next`. Not specific to TLAB, the nursery or the header
layout: any `scan_stack: false` collection on the process heap, a major in
the default layout included. `GC.collect` and every automatic collection
pass `scan_stack: true` and were never exposed. Fixed in `a00f5c47`: on a
stop-the-world heap `scan_stack: false` now leaves out the caller's own
stack and nothing else. `process_spec/regression/78_scan_stack_false_unborn_fiber_spec.cr`
forces the window: red in every run before, green in every run after.

## Rate

| where | build | runs | SIGSEGV |
|---|---|---|---|
| CI history, Darwin gates jobs 2026-10-01 .. 2026-10-19 | each run's tree | 458 (436 steps green + 20 failed later + 2 smoke failures) | **1** (this one; the other smoke failure is a deterministic assertion since removed) |
| CI history, Linux `Process-GC nursery+TLAB minor smoke` step | each run's tree | every ci.yml run listed (1 500, 2026-07-25 .. 2026-10-19) | 0 |
| probe 1, macos-latest | `233b3ad6` / `16b7e67c` | 53 / 146 until the first crash | 1 / 1 |
| probe 1, macos-15-intel | `233b3ad6` / `16b7e67c` | 46 / 272 until the first crash | 1 / 1 |
| probe 2, macos-latest, serial | `16b7e67c` / `a00f5c47` (fix) | 1 000 plain + 1 000 segv/poison each | **1 + 8** / 0 + 0 |
| probe 2, macos-15-intel, serial | `16b7e67c` / `a00f5c47` (fix) | 1 000 plain + 1 000 segv/poison each | **5 + 5** / 0 + 0 |
| probe 2, both runners, 4 loops at once | `16b7e67c` / `a00f5c47` (fix) | 4 × 300 per runner each | 0 / 0 |
| Linux local, 12-CPU x86_64 guest | `16b7e67c` | 300 plain + 300 `GCRY_SEGV_REPORT=1 GCRY_POISON_FREED=1` | 0 |
| Linux local, `taskset -c 0` | `16b7e67c` | 300 | 0 |
| Linux local, `taskset -c 0` + 3 busy loops on CPU 0 | `16b7e67c` | 200 | 0 |
| Linux local | `a00f5c47` (fix) | 300 plain + 300 segv/poison | 0 |

CI history: `ci-history/` (`scan_history.py` lists the jobs of every failed
ci.yml run whose failing step runs the gate and fetches their logs;
`classify.py` reads which make target failed and the fault; `exposure.py`
counts every Darwin gates job and whether its gate step ran green;
`exposure.txt`). The only other `nursery-tlab-smoke` failure in the history,
run 37328942780 job 111826755413 (2026-10-05, darwin x86_64), is the
kept-chunk assertion that has been Linux-only since 2026-10-06
(`ci-history/job111826755413-excerpt.log`).

Probe 1 (run [39382518495](https://github.com/sdogruyol/gcry/actions/runs/39382518495),
probe commit `f22c2cac`): the gate binary in a serial loop at the PR's base
`233b3ad6` and at the release-0.38.0 tip `16b7e67c`. The step ran under
`bash -e`, so each job stopped at its first failure, which is the count in
the table — four of four jobs crashed within 46–272 runs. The four outputs
are in `probe1/`. Both arm64 crashes are the CI crash to the byte (same
address, same frames); both Intel crashes fault at `0x0` in `Fiber#running?
+5` under the same `scan_all_fiber_roots` ← `released_chunk_probe` chain:
x86_64 raises a general-protection fault for the non-canonical
`0x6c696665725f6271`, and a #GP carries no fault address.

## The backtrace, read from the source

`Heap#scan_all_fiber_roots` (src/gcry/collect_scan.cr) walks
`Fiber.unsafe_each`, which is `Thread::LinkedList#unsafe_each`: `node =
@head; while node; yield node; node = node.next; end`. The two frames are
that loop and the block inlined into it. Per fiber the block calls
`mark_root_candidate(fiber.object_id)` (a lookup, no load through the
fiber), compares with `Fiber.current`, then `fiber.running?` — the first
load through the fiber pointer.

Layout (Crystal 1.21.0, 64-bit; `linux-local/offsets.cr`, output in
`linux-local/offsets.txt`): `Fiber@context` at 8, `Context@resumable` at 8,
so `running?` reads offset **16**; `Fiber@next` at **96**;
`instance_sizeof(Fiber)` 176.

`0x6c696665725f6271 - 0x10` is `0x6c696665725f6261`, little-endian
`"ab_refil"`. In the line `claim_probe` printed just before,

    "  claim_probe: free_after_minor=true free_after_major=true minors=12 tlab_hits=32 tlab_refills=10"

`"ab_refil"` starts at byte 84, which with `String`'s 12-byte header is
object offset **96** — `Fiber@next`. So the walk stood on an address that
held that `String`, read its `next` from the string's bytes, yielded it, and
faulted loading `@context.resumable` 16 bytes into it. The previous fiber's
`next` (or the list's `@head`) pointed at the start of a block that had been
a `Fiber` and was now that string.

Same block, not a coincidence of addresses: the interpolation is
`String.build(capacity)` with capacity 83 literal bytes + 5 × 15 = 158, so
`String::Builder` asks `GC.malloc_atomic(158 + 12 + 1)`, 172 with the
process heap's atomic slack — size class 192, the class of a 176-byte
`Fiber`. `to_s` shrinks it with `GC.realloc`, in place.

What freed a listed fiber: only a fiber that was **not yet listed** can be
freed while the list stays intact — every listed fiber is reachable from
`Fiber.@@fibers` and is marked by `scan_all_fiber_roots` in every collection
that scans stacks. `Thread#start` runs `Thread.threads.push(self)`, then
`Fiber.new(stack_address, self)`, which allocates the fiber and only at its
end pushes it onto the fiber list; until then the new `Fiber` is in that
thread's frame and nowhere else, and a stop holds the fiber list's mutex
from before its first suspend to after its last resume
(`lock_fiber_list_for_stop`), so a thread that reaches the push during a
collection waits there with the fiber in its frame. `run_collection_body`
gated `scan_all_fiber_roots`, `scan_thread_roots`,
`scan_other_thread_stacks` (registers and stacks of every other thread) and
`scrub_parked_fiber_stacks` on `scan_stack`, so a `scan_stack: false`
collection saw nothing of that thread.

The smoke never starts a thread, but gcry does: `IdleRelease.ensure_started`
(on by default on Linux and Darwin) runs `Thread.new(name: "gc-idle")` at the
end of the first collection, the smoke's first `minor_collect`. The smoke's
first `scan_stack: false` collection is the promoting minor at the top of
`claim_probe`, ten minors later. The only collections between it and the
`puts` are a `scan_stack: true` minor and major, which cannot free the
fiber, so the free was that minor's. The Monitor's fiber is allocated at
startup and listed long before; the idle thread is the only thread born
while the smoke runs.

Why macOS and not Linux is not measured. [INFERENCE] The idle thread has
to still be short of its push ten minors after it was created. On Linux a
new thread runs within microseconds and is past the push before the next
minor (0 of 1 100 local runs, single-CPU and contended included). On macOS
every stop suspends it through Mach and takes the fiber list's mutex, and the
ten minors run back to back; a thread that reaches the push while the mutex
is held may not get it before the next stop takes it again.

## The fix

`Heap#other_stacks_are_roots?(scan_stack)` is `scan_stack || @stop_the_world`
and gates everything but `scan_mutator_stack` in both root phases
(`run_collection_body` and `begin_incremental`). On a stop-the-world heap —
the process heap — `scan_stack: false` therefore leaves out the caller's own
stack only; every other thread's stack, registers and `Thread`, and every
other fiber, are roots as in any collection. A library heap
(`stop_the_world` false) keeps the old meaning, which its specs rely on.
Nothing in `src/` passes `scan_stack: false`; the callers are the public
`Heap#collect` / `#minor_collect` / `Gcry.collect` API, specs and benches. On
the process heap they are `bench/nursery_tlab_smoke.cr` and
`bench/nursery_headers.cr`, both single-mutator and both still asserting what
they did (the smoke's unrooted nursery object still vanishes;
nursery_headers' `--disabled` arm still loses its key). Default collections
take the same path as before, so no perf-ab was run.

## The regression

`process_spec/regression/78_scan_stack_false_unborn_fiber_spec.cr`, in a
child process (a red run publishes a freed fiber; `GCRY_IDLE_RELEASE_MS=0`
keeps the idle thread out): a holder thread takes the fiber list's mutex; a
new thread is started and stops in `Fiber.new`'s push with its fiber
allocated (the main thread waits until it is on the thread list and the
heap's allocation count has moved); the collector is told not to take the
mutex (`fiber_list_unlocked`) and runs 20 `scan_stack: false` collections
1 ms apart; then the holder lets go and the new thread asks whether its main
fiber is still an allocated block whose stack is its own. Majors in every
layout, minors when the nursery can be enabled (headered).

Child verdicts, Linux x86_64, 20 runs per row (`linux-local/spec78-verdicts.txt`):

| build | allocator | kind | before (16b7e67c) | after (a00f5c47) |
|---|---|---|---|---|
| default | bitmap | major | freed 20/20 | allocated 20/20 |
| default | `GCRY_BITMAP_ALLOC=0` | major | freed 20/20 | allocated 20/20 |
| headered | bitmap | major | freed 20/20 | allocated 20/20 |
| headered | bitmap | minor | freed 20/20 | allocated 20/20 |
| headered | `GCRY_BITMAP_ALLOC=0` | major | freed 20/20 | allocated 20/20 |
| headered | `GCRY_BITMAP_ALLOC=0` | minor | freed 20/20 | allocated 20/20 |

The same six rows, 50 children each, on macos-latest and macos-15-intel
(probe 2): freed 300 of 300 per runner on base, allocated 300 of 300 with
the fix. The default layout's minor rows are absent because a headerless
build has no nursery: its child prints "no nursery in this layout" and
passes.

## Probe 2

Run [39384888692](https://github.com/sdogruyol/gcry/actions/runs/39384888692),
probe commit `7eea2acb` on `a00f5c47` (`probe-ci.yml`; probe 1's is
`probe1-ci.yml`). Four jobs: macos-latest and macos-15-intel, each building
`base` (`src bench Makefile` checked out from `16b7e67c`, the release-0.38.0
tip, under HEAD's regression spec) or `fixed` (`a00f5c47`). Per job: the
regression's child 50 times per row, then the gate binary 1 000 times plain,
1 000 times with `GCRY_SEGV_REPORT=1 GCRY_POISON_FREED=1`, then four loops
of 300 at once with `GCRY_SEGV_REPORT=1`. Every failing run's output is in
`probe2/<runner>-<arm>/`.

| runner | arm | plain | segv + poison | 4 × 300 at once | regression 78, 300 children |
|---|---|---|---|---|---|
| macos-latest | base | 1 / 1 000 | 8 / 1 000 | 0 / 1 200 | freed 300 / 300 |
| macos-latest | fixed | 0 / 1 000 | 0 / 1 000 | 0 / 1 200 | allocated 300 / 300 |
| macos-15-intel | base | 5 / 1 000 | 5 / 1 000 | 0 / 1 200 | freed 300 / 300 |
| macos-15-intel | fixed | 0 / 1 000 | 0 / 1 000 | 0 / 1 200 | allocated 300 / 300 |

Serial runs, base against fixed (one-sided Fisher): macos-latest 9 / 2 000
against 0 / 2 000, p ≈ 0.002; macos-15-intel 10 / 2 000 against 0 / 2 000,
p ≈ 0.001; both, 19 / 4 000 against 0 / 4 000, p ≈ 2 × 10⁻⁶. The four
concurrent loops crashed in neither arm (0 / 2 400 base); [INFERENCE] four
processes on the runner's few cores change when the idle thread gets the
CPU, and the window wants it late but not too late.

Every base crash is the same chain, `scan_all_fiber_roots` ←
`run_collection_body` ← a `scan_stack: true` collection in one of the two
probes:

- arm64, `0x6c696665725f6271` in `released_chunk_probe`'s major: 6 of 9
  (plain 622; segv/poison 148, 274, 380, 551, 912) — the CI crash.
- arm64, **`0xdeadf2eedeadf2fe`** in `claim_probe`'s second minor (the
  `scan_stack: true` one): 3 of 9 (segv/poison 11, 133, 317). That is
  `GCRY_POISON_FREED`'s pattern `0xdeadf2eedeadf2ee` + 0x10: the walk read
  `next` out of the freed, poisoned fiber block — before anything was
  allocated in it — and `running?` loaded through it. The use-after-free,
  observed directly.
- x86_64, `0x0` in `Fiber#running? +5`, 10 of 10: in `released_chunk_probe`'s
  major 9 times, in `claim_probe`'s major once (segv/poison 954, which the
  reporter names: "gcry's freed-block poison … is in the faulting context …
  a use-after-free").

So every poisoned sighting is in the first or second fiber walk after the
promoting minor, the only `scan_stack: false` collection before it.
[INFERENCE] In the rest the idle thread's push came after `claim_probe`'s
major, so the next walk was `released_chunk_probe`'s, by which time the
printed line had taken the block.

## Files

- `ci-history/` — the crash and the other smoke failure, the scripts and the exposure count.
- `probe1/`, `probe1-ci.yml` — probe 1's four first crashes and its workflow.
- `probe2/`, `probe-ci.yml` — probe 2's summaries, every failing run's output, and its workflow.
- `linux-local/` — the loop script, smoke loop counts, regression 78 verdicts, the layout program and its output.

The probe branch `probe/tlab-nursery-crash-darwin` (`f22c2cac`, then
`7eea2acb` force-pushed over it) was deleted after the runs; both workflows
are kept here.
