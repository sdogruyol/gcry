# Running out of memory hung the process, three layers deep

2026-08-29, Linux x86_64. Found by inspection while hunting something else, then
made deterministic: `ulimit -v` plus a child that retains everything it
allocates. **5 of 5 children spun at 100% CPU forever**, no output, no error, no
watchdog line. Every layer below was uncovered by fixing the one above it, and
all three are on the default path — no knob is involved.

## The reproducer

`bench/oom_no_hang.cr` (new, gated as `make oom-no-hang`, wired into CI): the
child caps its own `RLIMIT_AS` at 512 MiB and appends 40 KiB `Bytes` to an array
forever, so no collection can free anything and the allocator has to reach its
refusal. The parent gives it 60 s. Deterministic — no races, no rates.

Before: `large: 3 of 3 hung`. After: `0 of 3 hung`, both size paths naming the
failure. Verified by building the gate against the pre-fix tree
(`git stash push src/gcry/heap.cr`), which is the only way to know a gate can go
red.

## Layer 1 — `raise` under the allocator's own lock

```
#0  pause                          intrinsics.cr:191
#1  lock                           spin_lock.cr:11
#2  alloc_old_small                tlab.cr:131        ← wants the freelist lock
#3  allocate                       heap.cr:578
...
#8  Array#initialize               array.cr:122
#10 CallStack#unwind               libunwind.cr:41
#13 raise                          raise.cr:242
#14 map_chunk                      heap.cr:1507       ← raise OutOfMemoryError
#15 refill_size_class              heap.cr:1054
#16 alloc_old_small_locked         heap.cr:764
#17 alloc_old_small                heap.cr:737        ← *holds* the freelist lock
```

`map_chunk` raised when `mmap` refused. Every caller holds a non-reentrant
`Crystal::SpinLock` across that call — `alloc_large` inside `with_alloc_lock`,
`refill_size_class` inside the size-class freelist lock — and **`raise` in
Crystal allocates**: `raise.cr:261` is `exception.callstack ||=
Exception::CallStack.new`, a `CallStack` is an `Array`, and that `Array` goes
straight back into `allocate` and asks for the lock the raising thread is
already holding. Self-deadlock, one thread, no race.

`map_chunk` now returns null. `refill_size_class` returns with the freelist
empty, `alloc_large` returns a null user pointer, `alloc_old_small_locked` and
`alloc_nursery_locked` return null instead of raising, and the *entry points* —
holding nothing — turn that into an `OutOfMemoryError`. `alloc_old_small`
already stated the rule at its own tight-grow collect: never collect under the
freelist lock. It applies to raising too, for the same reason.

## Layer 2 — the emergency collect was inside the lock as well

The same function had this, four lines up:

```crystal
if Gcry.mmap_failed?(ptr) && !@collecting && @enabled && !@tlab_enabled
  collect(scan_stack: true)
```

with the comment *"Never collect here under TLAB: refill holds a freelist
SpinLock"* — the exact hazard, recognised, and the guard excluded only the TLAB
path although the **TLAB-off** refill holds a freelist lock just the same. A
collection re-takes both locks: the after-world sweep locks
`freelist_lock_ptr(class_index)` (`collect_sweep.cr:85`) and
`flush_pending_large_release` opens with `with_alloc_lock` before it checks
anything. So the emergency collect could only ever deadlock; the OOM recovery
path had never once worked.

Moved to `retry_after_emergency_collect?`, called from the entry points with no
lock held: one collection, one retry, then the error stands.

## Layer 3 — the retry recursed, twice, in two different ways

With the retry outside the lock, the hang became a **stack overflow**, 3 of 3:

```
retry_after_emergency_collect? → collect → run_collection
  → ensure_static_root_cache → (parses /proc/self/maps) → allocate → …
```

A collection allocates. At the edge of the address space those allocations fail
too, and `@collecting` — which is not set for the whole of `collect` — did not
stop the second failure asking for a third collection. `retry_after_emergency_collect?`
now holds its own `Atomic(Int32)`: one emergency collection at a time,
process-wide, and a thread that finds it taken raises instead, which is the
honest answer when another thread is already reclaiming everything there is.

That left the *raise* recursing on its own — the frame histogram of the
surviving overflow is unambiguous:

```
174 × raise → CallStack::new → unwind → Array → malloc → allocate → alloc_old_small → raise
```

So the first raise stays the normal one, with a true backtrace, and any raise
nested inside it uses a `@oom_error` built at boot with its `callstack` already
set — `raise` finds nothing left to allocate. Its backtrace is the boot stack
and the message says so.

## Measured

| tree | large path | small path |
|---|---|---|
| before | **5 of 5 hung** (100% CPU, `state=R`, 205 s of CPU on one child) | clean error |
| + raise/collect moved out of the lock | 3 of 3 stack overflow | clean error |
| + non-reentrant emergency collect | 3 of 3 stack overflow (the raise recursion) | clean error |
| + allocation-free nested raise | **3 of 3 `OutOfMemoryError`** | clean error |
| gate, fixed tree | 0 of 3 hung | 0 of 3 hung |
| gate, pre-fix tree | 3 of 3 hung → FAIL | 0 of 3 |

`make spec` 169, `make spec-process` 27, `make oom-no-hang` green,
`make large-cache-race` green, `make page-release-corruption` green 4 of 4 (see
below), formatter and knob gate clean. New counter `emergency_collects` on
`/gc-stats`: non-zero means the process has been to the edge of its address
space, which is worth knowing before reading anything else there.

## A gate that was failing on its own noise

`make page-release-corruption` went red twice while checking the above, on its
*engagement* check rather than on corruption — and the first reading was "the
allocator change broke it", which it had not. The check compared the HOLED arm's
`dontneed_bytes` against the control arm's, and that counter belongs to neither
walk: it is shared with `flush_pending_dormant_chunks`. Seven runs measured the
control at 0, 0, 0, 1.97, 1.97 and 7.88 MB — a floor moving 4× between runs —
against a HOLED arm at 7.79–11.98 MB. Both thresholds tried, `off_dn * 4` and
`off_dn * 2`, sat *inside* the range they were meant to sit below, and failed a
third to a half of runs saying "no chunk went HOLED" about a walk that had just
unlinked twelve thousand page runs.

Each walk is now asked about itself: `page_release_unlinked_chunks` for the
HOLED arm (10,644–12,824 there, **0** on both other arms in every run) and a
16 MiB absolute floor for mostly-empty (64–67 MB whenever it engages). 4 of 4
green afterwards.

An engagement check that flaky is worse than none, because it is read as a
regression in whatever changed last.

## Also today, from the other hunt

The `dormant_flush_race` refusal probe added this morning fired for the first
time, and it closes the open question in
`../2026-08-29-silent-hang-named/FINDINGS.md`:

```
GC.free: not a live gcry allocation — no release on record;
in bounds: true; on @chunks: no; second lookup: still nil;
the chunk is on the collector's release queue, detached and not yet unmapped
— base 0x7fa9e9a60000, 585728 bytes queued in total
```

The window is named: a mutator's `trim_large_cache` detached that chunk and
queued it for `flush_pending_large_release`, where it sits off `@chunks`, out of
the index, and still mapped. The trim only ever detaches chunks that are already
**on the large cache**, which a chunk holding a live block has no business being
on — so the defect upstream is a lost root: the sweep took a live large block
for dead and cached its chunk. That is the family of
`../2026-08-26-registers-were-never-roots/` and
`../2026-08-27-signal-frame-below-sp/`, reached from a new direction and with a
1-in-90 reproducer instead of a 1-in-780 one.
