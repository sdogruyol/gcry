# Regression 79 and the IOCP forwarder's birth (2026-11-07)

`test (windows arm64, headers)` failed in PR CI run 42355329221 (job
128352059172, `907d539b`) at
`process_spec/regression/79_alloc_entry_frame_uninitialized_spec.cr:76`,
`heap.collections.should be > collections_before`: `Expected 0 to be
GreaterThan 0`. The spec's one allocation at `gc_threshold = 1` did not
collect, and none had run before it.

**Cause: the IOCP forwarder thread's birth.** On Windows, `kernel.cr` starts
`Crystal::EventLoop::IOCP.start_forwarder_thread` before `main`: a thread
named `IOCP`. Its `Thread#start` makes its main fiber current and then
copies its name to UTF-16 for `SetThreadDescription` (`System.to_wstr`), an
allocation that passes every `maybe_collect` gate (it is not `SYSMON`, and
its fiber is current). After that it blocks in
`GetQueuedCompletionStatusEx` and allocates nothing. On windows-11-arm the
birth is slow enough to land inside the spec's window: the forwarder's
allocation sees debt ≥ 1, takes the collection section, and starts a
collection. The spec's own allocation then finds the section taken and
coalesces (`acquire_post_stw`, `@collect_coalesced` +1), returning with no
collection. The forwarder's collection finishes after the spec's check.
When the forwarder's collection reaches its hook while the spec's hook is
still installed, the hook measures from the forwarder's
`collect_entry_sp`, on another stack, up to the main thread's SP. That
walk crossed unmapped memory and crashed on a non-main thread
(`Invalid memory access` at a 1 MiB-aligned address, 3 runs below).

This is the same kind of race as regression 86's idle-thread birth
(`../2026-11-03-reg86-idle-birth/`): a thread the process started on its
own allocates inside a threshold-1 window.

## Evidence

Probe workflow `probe-reg79.yml` with `probe-loop.ps1` (both in this
directory; branch `probe/reg79-collect`, deleted). windows-11-arm (the
pinned native Crystal 1.21.0 and MSYS2 CLANGARM64 setup of `ci.yml`) and
windows-latest (Crystal 1.21.0). Each job builds the specs as
`ci/windows.ps1` does (`--release -Dgc_none`, plus `-Dgcry_block_headers`
for headers and freelist, `GCRY_BITMAP_ALLOC=0` for freelist only) and
loops each binary 200 times. `diag.patch` (against the fixed spec) prints
the heap state around the allocation and the name of the thread whose
collection the hook saw. It only reads state and changes no behaviour;
`GCRY_PROBE_NOSETTLE=1` skips the fix.

Run 42359794724 (`907d539b` + diagnostics, no fix), regression 79:

| runner | default | headers | freelist |
|---|---|---|---|
| windows-11-arm | 6 / 200 | 7 / 200 | 0 / 200 |
| windows-latest | 0 / 200 | 0 / 200 | 0 / 200 |

Every miss had the same state:

```
diag79: nocollect coll 0->0 bsg 171168->176000 unc=4352 thr=8388608 ops 21->23 coal 0->1 miss_thr 0->1 miss_refill 26->27 en=true cing=false sup=0 inc=false idle_armed=true threads=DEFAULT-0,IOCP,SYSMON
```

The debt was 171 KB credited plus 4 KB uncredited, well over the
threshold of 1. Collection was enabled and nothing suppressed it. The hit
path missed on the threshold (`miss_thr` +1), so the slow path ran.
`maybe_collect` ran twice in the window (`ops` +2): once for the spec's
allocation and once for another thread's. The spec's collection was
coalesced (`coal` +1): another thread held the section. The listed
threads were the main thread, `IOCP` and `SYSMON`, and in 3 of the 13
misses `SYSMON` was not listed yet: both runtime threads were still being
born. `SYSMON`'s allocations never collect (`monitor_thread?`), and the
idle thread is not born before the first collection. That leaves the IOCP
forwarder. The seventh headers failure was the crash.

Run 42360512944 (the fix, with an arm without it, same diagnostics):

| runner, spec | arm | default | headers | freelist |
|---|---|---|---|---|
| windows-11-arm, 79 | without the settle | 4 / 200 | 8 / 200 (2 crashes) | 0 / 200 |
| windows-11-arm, 79 | `settle_runtime_threads` | **0 / 200** | **0 / 200** | **0 / 200** |
| windows-latest, 79 | both | 0 / 200 each | 0 / 200 each | 0 / 200 each |
| both runners, 86 | both | 0 / 200 each | 0 / 200 each | 0 / 200 each |

With the settle, the hook saw the main thread's collection in all 1 200
runs of 79 (`collector=DEFAULT-0`). In the misses without it, the hook saw
no collection at all: the forwarder's collection finished after the spec
had removed the hook.

Run 42361690172 (the pushed specs themselves, with `credit_window_debt`
below, no diagnostics; `probe-loop.ps1` and `probe-reg79.yml` here are
that run's). On both runners and all three variants: 79 and 86 release,
0 of 150 each; 27 debug run alone, 0 of 100 each. Every run printed
`stale79: 0` and `fixed 0, no gap 0` for 86, with control 27–44. That is
0 of 450 per spec on each architecture, and 0 of 300 for 27.

## Fix

`process_spec/support/collection_window.cr`, shared by 79, 86 and 27, has
two functions. 86's own `stale86_settle_idle_thread` is folded into the
first.

`settle_runtime_threads`, at the start of the example, runs the process's
first collection, which starts the idle thread if it is armed. It then
waits until:

- the idle thread is signal-exempt (86's earlier fix);
- on Windows builds where `kernel.cr` starts it, a thread named `IOCP` is
  listed;
- every listed named thread other than the caller has its Windows thread
  description (`GetThreadDescription`). `SetThreadDescription` runs after
  the `to_wstr` allocation has returned, so by then that allocation, and
  any collection it ran, is over.

The wait fails after 10 s.

`credit_window_debt` runs inside each threshold-1 window, before the
stack fill and before 86's wipe watch. The settle's collection exposed a
second precondition the windows had only met by luck: the debt the slow
path checks has to be at least 1. `maybe_collect` reads the credited
counter (`@bytes_since_gc`), and the slow path credits its own cursor set
only after that (`bitmap_alloc_locked`). An allocation whose hit path
missed for want of a block, right after a collection with nothing
credited since, therefore sees 0 and does not collect. With the settle
alone, 27, 79 and 86 in one debug process (bitmap layout) failed 79 at
`Expected 10 to be > 10`, with credited debt 0 before the window
(`bsg 0->80`, `miss_refill` +1, `miss_thr` +0). Without the settle, the
same run had 1 280 bytes credited and passed. 86's third arm had shown 32
credited bytes in the first probe, so it was near the same edge.
`credit_window_debt` credits every cursor set (`Heap#bytes_since_gc`) and,
if that is still 0, allocates 64 bytes and credits again; it fails if
there is still no debt.

No check changed.

Audit: of the process regressions that check that collections increased,
only 79 and 86 force one allocation at `gc_threshold = 1`. One more relies
on an automatic collection: 27's "runs the collection allocation would
have run" and "is 1 only while a sliced cycle is in progress" call
`GC_collect_a_little` on a due debt, which is `collect(coalesce: true)` and
so skips a collection a newborn's allocation started past the same debt.
Its first example's `LibGC.collect` starts the idle thread, so run alone
its second example is the window. Inside the process suite earlier files
have collected long before, which is why it has not been seen. It takes
the settle too. 28, 29 and 40 call `GC.collect`/`LibGC.collect`, which wait
for a full collection that began after the call. 56 allocates MiB blocks
until a collection lands. 10 and 21 check totals over many collections.

Local, Linux x86-64: `make alloc-entry-frame` (`stale79: 0`,
`control 27, fixed 0, no gap 0`); 50 runs each of 79 and 86 on the
freelist and bitmap header builds, 0 failures; the debug `crystal spec`
of both passes; format, `make lint`, `make windows-typecheck` and
`make darwin-typecheck` pass. The helper's Windows binding was also
cross-compiled for `aarch64-windows-gnu`.
