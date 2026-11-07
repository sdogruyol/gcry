# An incremental cycle began outside the collection section (2026-11-07)

Branch `inc-begin-040`, on `release-0.40.0` (`a40ec329`). Local x86-64
Linux, 12 CPUs, Crystal 1.21.0 unless named; every heavy step under the
shared lock, one per hold.

## 1. The residual

`2026-11-06-reg99-race/FINDINGS.md` § 5 and the review of that work
(§ 3): `collect_a_little` called `begin_incremental` before it queued for
the collection section (`lock_post_stw`). Its entry checks read
`@collecting` false, but a full collection (`run_collection_body`) sets
`@collecting` only once it holds the section and is past its prelude (the
in-section drop of an open cycle, `StwWatchdog.ensure_started`, the
coalesce check). The review inferred, without reproducing it, that such a
begin could freeze the collector mid-drop and that the rest of the drop
undid the new cycle's arm.

## 2. What the window is

The begin does not need to land inside the prelude. `begin_incremental`
sets `@collecting`, then takes `lock_write`; if the collection has reached
its own `lock_write` first, the begin waits there through the
collection's whole stop and takes the world the moment the collection
releases it (`start_world`, `unlock_write`) — in the post-stop passes,
with the collection still holding the section, before its sweep after
the world (`@lazy_sweep_pending`, the default: `lazy_sweep` true, TLABs
off). So the window is every slicing thread that read `@collecting` false
before the collection set it, however long it then takes to reach its
begin. Two orders, both reproduced:

**Post-stop (regression 110).** The begin's stop clears every mark
(`clear_all_marks`) and marks the roots without tracing them. The
collection's lazy sweep then reads those marks: it frees everything a root
does not point at directly. Its re-arm (`arm_page_barrier_after_major`;
no nursery, no `incremental_auto`, the process default) takes the begin's
mprotect barrier down, so the cycle stays open with backend `None`. The
begin's `ensure` writes `@collecting = false` while the collection still
runs its post-stop passes.

**Mid-drop (probe).** With a cycle open, the collection's
`abort_incremental` writes `@inc_active = false` first. A begin that
lands right after that (probe hook there, `mid_drop_probe.diff`) arms its
own cycle; the rest of the drop clears its grey entries
(`@mark_stack.clear`), unprotects and frees its cards
(`disarm_mprotect_barrier`) and sets the backend `None`. The full
collection then re-marks from every root under the section, so nothing is
freed (the review's reading), but the cycle it leaves open has no barrier
and nothing grey (`mid_drop_probe.txt`, five runs per arm, identical):

```
control: hook: ticket=1 open=1 mprotect=1 stack=36 | after collect: open=true  backend=none stack=0 | slice: open=1 mprotect=0 stack=0  | chain 20000/20000
fixed:   hook: ticket=1 open=0 mprotect=1 stack=36 | after collect: open=false backend=none stack=0 | slice: open=1 mprotect=1 stack=36 | chain 20000/20000
```

In the control the second thread began during the drop (open at the hook,
its 36 root entries on the stack) and the drop's remainder undid it; fixed,
the thread queued first and began after the collection, on mprotect.

## 3. Regression 110

`process_spec/regression/110_incremental_begin_in_section_spec.cr`, each
arm in its own process, Linux only (the skip mark elsewhere or when no
cycle can begin on a barrier). Automatic collection and the idle thread
off (`GCRY_IDLE_RELEASE_MS=0`), mprotect preferred; a 20 000-block chain
whose head is an explicit root. A second thread calls `collect_a_little`;
the new research hook `Heap.inc_begin_hook` holds it after its entry
checks and releases the main thread into `collect`, then waits for that
collection's `post_stw_hook(:after_start_world)` (world running, section
held, lazy sweep not run). The post-stop hook waits for the second
thread's ticket for the section and records the cycle, `@collecting` and
`@lazy_sweep_pending`.

- **Control** (`Heap.inc_begins_in_section = false`, the old order): cycle
  open at the hook, `@collecting` already false, lazy sweep pending; after
  the collection the cycle is open with backend `None` and 1 of 20 000
  chain blocks is allocated (the head). The collection swept the runtime's
  own objects with the chain, so the child reports through `write(2)` from
  a stack buffer and leaves through `_exit` while the slice is parked in
  `inc_slice_locked_hook`; the parent asserts the control mark, which the
  child prints only when every one of those conditions held.
- **Fixed**: no cycle at the hook, `@collecting` true, lazy sweep pending;
  the slice begins under the section, runs on mprotect and finishes; 20 000
  of 20 000 alive.

A first version waited on the hooks' flags through `pointerof(@@flag)`.
Its control failed "the slicing thread never reached its begin" in 3 of
1 000 children on headers + `GCRY_BITMAP_ALLOC=0` unpinned (0 of 300 on
the other three configurations) and 4 of 1 000 under a 10-process CPU
load; with timing diagnostics added, 32 of 500. A stage diagnostic put
the slicing thread past `@@collect_go.set(1)`, 0.1–1.6 µs after the main
thread began waiting, and the flag read 0 afterwards. Cause, in the test:
on Crystal 1.21 `pointerof` on a class variable whose initializer is a
call (`Atomic(Int32).new(0)`) runs the initializer again — the emitted
code calls `~Mod::var:init` (IR read) — so the main thread's
`pointerof(@@collect_go)` reset a flag the slicing thread had just set
whenever the set landed first. `pointerof_class_var.cr` shows it alone:

```
after storing 5: call-initialised read by name 0, through pointerof 0; literal through pointerof 5; uninitialized through pointerof 5
```

The waits now read the flags by name in a block (`wait_until`). Every
`pointerof(@@…)` in `src/` targets a literal or `uninitialized` class
variable, which this does not affect.

## 4. Fix

`src/gcry/collect.cr`, `collect_a_little`: a slice that finds no cycle
(`begins`) queues for the section first and begins there
(`begin_incremental` unless a slice queued ahead began one); a begin that
arms no barrier releases the section and returns false as before. A slice
that queued expecting an open cycle keeps the re-check (returns false if
the cycle ended ahead of it). `inc_slice_locked_hook` still runs after
that point. Research knob `Heap.inc_begins_in_section` (class property,
no `Heap` field moves); false restores the begin before the section.
Boehm begins a cycle under its allocation lock
(`GC_collect_a_little_inner`).

**Lock order.** The begin now runs holding the section, then
`lock_write`, then the stop — the order of `run_collection_body` and of
every slice already (each slice took the section, then `lock_write`).
`begin_incremental` takes no other gcry lock. Threads waiting for the
section are in `pthread_cond_wait` and hold nothing the stop needs, as for
any collection. No path calls `collect_a_little` holding the section: the
re-entrant cases return at the entry checks (`@collecting`, an external
`GC.stop_world`, finalizers draining). `begin_incremental` has no other
caller.

**Default path.** `bench/churn.cr`, `--release --no-debug`, base
`a40ec329` vs this branch, objdump per symbol, addresses and targets
normalised (`mc_diff.py`, `mc_diff.txt`): of 981 functions only
`collect_a_little` changed (554 → 605 instructions) and
`Crystal::System::print_error` (register allocation only; the crash-report
writer); the out-of-line `lock_write` and `mark_large_alloc_in_flight`,
whose only remaining caller had been `collect_a_little`, are now inlined
there. `run_collection_body`, `collect`, `maybe_collect` and the
allocation paths are instruction-for-instruction the same (rebuilding the
base gives a byte-identical binary, so the comparison is not noise). The
keep rule applies when default-path machine code changes; it does not, so
no Perf A/B was run. Function addresses after `collect_a_little` shift
(51 instructions, two removed functions) [placement only].

## 5. Rates

`child_loop.sh` over `quick-entry.cr` (99's *race*, *nocards* and
*softdirty* arms, 108, 110; entries are built from the tree's root), 100
children per arm per row, Crystal 1.21. `rates-final.txt`, the final
test:

| build | pinned to CPU 0 | 110 fixed | 110 control | 108 fixed | 108 control | 99 (six arms) |
|---|---|---:|---:|---:|---:|---:|
| headerless | no | 0 | 0 | 0 | 0 | 0 each |
| headerless | yes | 0 | 0 | 0 | 0 | 0 each |
| headers + `GCRY_BITMAP_ALLOC=0` | no | 0 | 0 | 0 | 0 | 0 each |
| headers + `GCRY_BITMAP_ALLOC=0` | yes | 0 | 0 | 0 | 0 | 0 each |

Failures out of 100; every control prints its mark (the loop requires
it). Under a 10-process CPU load (`loaded_loop.sh`, headers +
`GCRY_BITMAP_ALLOC=0`, unpinned; `rates-loaded.txt`): 110 fixed 0 of 500,
control 0 of 500. `rates.txt` is the first version's run (§ 3: 2 of 100
control failures on headers unpinned, every other arm 0).

## 6. Checks

`checks.sh` (`checks.txt`, on the fix with the first version of the
test): `verify.sh` after `rm -rf lib/ameba bin/ameba` (format, lint,
`spec/all_specs.cr` headerless / headers / `GCRY_DEBUG_INVARIANTS=1`,
`process_spec` headerless / headers / headers + `GCRY_BITMAP_ALLOC=0`),
`make windows-typecheck`, `make darwin-typecheck`, `make
alloc-entry-frame`, `process_spec` on Crystal 1.22.2, and the stress
loops `pattern-fuzz-(nursery|incremental)-mprotect|claim-stress.*` at
scale 0.5 (`stress-summary.txt`: 367 runs, 0 failures, 0 stalls): every
step exit 0. After the test's wait fix (`src/` unchanged since),
`checks-final.txt`: `verify.sh` again and `process_spec` on 1.22.2, every
step exit 0 — `spec/all_specs.cr` 307 / 330 / 307 examples,
`process_spec` 457 / 458 / 458 and 457 on 1.22.2, 0 failures, 2
pending.

## Files

- `quick-entry.cr`, `child_loop.sh`, `loaded_loop.sh`, `rates.txt`,
  `rates-final.txt`, `rates-loaded.txt` (§ 3, § 5).
- `pointerof_class_var.cr` (§ 3).
- `mid_drop_probe.cr`, `mid_drop_probe.diff`, `mid_drop_probe.txt` (§ 2).
- `mc_diff.py`, `mc_diff.txt` (§ 4).
- `checks.sh`, `checks.txt`, `checks-final.txt`, `stress-summary.txt`
  (§ 6).
