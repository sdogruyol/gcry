# The fiber-creation use-after-free: the sweep freed it, and the mark was complete

> **Note (later the same day):** the "CI qualifies this" section below is
> **retracted** — see the correction that precedes it. The CI catch was a swept
> block whose `SWEPT` flag a freelist rebuild had erased, not an explicit free.

2026-08-16, x86_64 WSL2, Crystal 1.21.0, `bench/nested_spawn_uaf.cr`.
Follows `bench/log/linux/2026-08-16-uaf-holders/FINDINGS.md`, which named the
chain: the freed block is the live execution context's stack-pool
`Deque(Fiber::Stack)` buffer, held by the context's own `Fiber::StackPool`.

That left one question — *why does the mark not keep it alive* — and this round
answers it in the least convenient way: **the mark does keep everything alive.
It is complete at every collection.** The defect is not a missed heap edge.

## The repro is 20× cheaper

Before anything else, because it changes what is affordable to measure:

| config | crashes | per run |
|---|---|---|
| `ROUNDS=200 FIBERS=64` (the documented one) | 6/15 | ~40 s |
| **`ROUNDS=20 FIBERS=64`** | **4/12** | **~2 s** |
| `ROUNDS=50 FIBERS=64` | 3/12 | ~5 s |
| `ROUNDS=20 FIBERS=256` | 1/12 | ~2.6 s |
| `ROUNDS=1 FIBERS=1` | 0/30 | ~0 s |

Everything below runs at `ROUNDS=20 FIBERS=64`, n=24 per arm.

## Who freed it: the sweep, and now the header says so

`BlockHeader::Flags::SWEPT` (0x80) is set alongside `FREE` by the sweep's
freelist link and left clear by an explicit `Heap#free`, and the crash report
reads it back. Measured across three crashes:

```
gcry: the free that wrote it was of the block at 0x…, still FREE, size 3072,
      flags 0x81 — freed by the SWEEP, so the collector decided it was garbage
```

"The collector decided it was garbage" and "the program asked" are different
defects with different owners, and until this bit existed the poison could not
tell them apart.

## Retracted: there was no "other free path" — the flag was being erased

**The section below is wrong, and is kept because the reasoning in it was
plausible and the correction is the point.** It read a CI catch's `flags 0x1` as
"freed by an explicit `Heap#free`" and built three further observations on top.

`Flags::SWEPT` was set only in `push_size_class_free`. Four sites in
`collect_sweep.cr` — the freelist **rebuild** paths, which re-link blocks that
are *already free* after a chunk is emptied or page-released — reconstructed each
header with a bare `Flags::FREE` and **erased the bit**. A block the sweep had
genuinely reclaimed therefore read as an explicit free as soon as a rebuild
touched its size class.

Measured both ways on a workload that empties whole chunks (20 000 × 256 B, four
collections):

| | free blocks still findable | carrying `SWEPT` |
|---|---|---|
| flag carried through the rebuild | 278 | **278** |
| bare `FREE` (the bug) | 278 | **0** |

And the discriminator itself, unchanged: an explicit `GC.free` leaves `SWEPT`
clear, a swept block sets it — 199 of 200 dropped blocks, the 200th retained by
a conservative stack hit.

Also checked, because the retracted section rested on it: `Heap#free` is called
**zero** times in a fiber-spawning workload, and so is `realloc(size: 0)`. The
harness does not free either, and Crystal's stdlib calls `GC.free` only from the
zlib and GMP allocator hooks. There was never a plausible caller.

Gated in `process_spec` for the **discrimination** — a swept block sets the flag,
an explicitly freed one does not — and that half is broken on purpose and
observed red.

**The rebuild preservation is not gated**, and that is worth saying plainly
because it was claimed here on 2026-08-16 and the claim did not survive. The
rebuild only runs when chunks are released, and a released chunk takes its
blocks out of `find_block` with it: a workload that triggers the rebuild leaves
nothing to inspect, and one that keeps blocks inspectable does not trigger it.
Four arrangements were tried on 2026-08-17 — retaining nothing (flaky: 278
findable free blocks one hour, 0 the next), retaining half, retaining one in
200, and holding empty chunks — and breaking the flag on purpose passed in every
one except the flaky arrangement. The evidence for the fix is the standalone
measurement above (278 of 278 against 0 of 278); the gate is the discrimination
only.

### The retracted reading, as it stood

The first tagged catch in CI (run `31963103652`, `make ec-queue-audit`, aarch64)
says something the local repro never showed:

```
gcry: the free that wrote it was of the block at 0xfffce8e62d70, still FREE,
      size 384, flags 0x1 — freed by an explicit free, not by the sweep
gcry: holders — explicit roots: 0 of 0 point into it
gcry: holders — heap: block 0xfffce8fd3d38 size 32 type_id 211 flags 0x0
      holds it at +16 (block+24)
gcry: holders — heap: 1 word in 1 live block, from 15512 blocks in 13 chunks.
      current mark gen 4, collections 3
```

`flags 0x1` — **`SWEPT` is clear**. Every crash measured locally in this file was
`0x81`: the sweep decided the block was garbage. This one was handed back by
`Heap#free`, i.e. the program asked. That is exactly the distinction the flag was
added for, and it fired on its first CI catch.

Three more differences from the local shape, none of them explained yet:

- **size 384** — 16 `Fiber::Stack` entries, the *smallest* capacity in the
  original 384 / 768 / 1536 / 3072 sequence, against 1536 and 3072 locally;
- the holder's pointer is at **block+24**, an *interior* offset one entry in,
  where every local holder pointed at **block+0**. A `Deque` keeps `@buffer` at
  the base and tracks `@start` as an index, so an advanced buffer pointer is not
  `Deque`'s shape — `Array#shift` is;
- **3 collections in**, i.e. very early, against 16–200 locally.

So "the sweep freed it" is true of the local repro and **not** of this catch.
Either the same defect is reachable through two free paths, or `ec-queue-audit`
and `nested_spawn_uaf` are hitting two different ones. Nothing here settles that,
and the report was truncated before its stacks and owner sections — several
threads were faulting at once and the output interleaved.

**What it settled, in the end:** not that there are two free paths, but that a
flag is only as good as every site that rewrites the word it lives in. The bit
was added, used to draw a conclusion, and the conclusion found the *flag's* bug
rather than the collector's.

## 2026-08-17: both instruments run together, and they contradict each other

With the fast observer (`GCRY_THREAD_CENSUS=1`, which brings the defect back —
16/25 against 0/20 with it off) the crash report and the mark audit can be run
in the same process. Ten crash reports and six audited crashes:

| | |
|---|---|
| freed by | **SWEEP, 10 of 10** (the flag now survives freelist rebuilds) |
| block size | 1536 (×8), 768 (×2) — `Deque(Fiber::Stack)` capacities |
| holders | **one**, every time: a 32-byte block, `type_id` 209, pointer at +16, value `block+0` — the deque's `@buffer` |
| mark audit | **zero missed edges, 6 of 6 crashing runs** |

Read together they cannot both be complete:

- at fault time a **live** `Deque` points at a block the sweep freed;
- at sweep time **no surviving block** pointed at any block about to be freed.

The resolution is in what the audit walks: **only marked parents**. If the
`Deque` object itself was unmarked at that collection, its edge to the buffer is
never examined, and the audit reports a clean bill while the very edge that
matters goes unchecked. A "the mark is complete" result is therefore weaker than
it reads — it says *surviving* objects have no dangling edges, not that nothing
dangling survives.

### The other side, audited: nothing in the heap points at the dying block

`GCRY_MARK_AUDIT_ALL=1` drops the "parent must be marked" filter and walks
**every** used block, reporting the parent's mark state with each edge into a
block about to be freed. Across five crashing runs it reports **nothing at all**
— not from marked parents, not from unmarked ones.

So at the moment the buffer is freed, **no pointer to it exists anywhere in the
used heap**. The `Deque` does not point at it yet. And at fault time the
poison-holder search finds it on a **running fiber's stack** (17 hits across the
crash reports, all `(running)`), with the `Deque` → `Fiber::StackPool` chain
above it.

That fixes the sequence beyond argument:

1. the buffer is allocated and held **only** in a register or a stack slot of a
   running thread;
2. a collection runs and frees it, because nothing it scans holds it;
3. the mutator then stores it into `@buffer`, and the next read of the deque
   walks into poison.

Which is the birth window, for the buffer rather than for a `Fiber` or a
`Thread`.

### And the suppressor is still not the rooting

The obvious reading of that sequence — the birth grace works because it roots
the newborn buffer — is **wrong**, and this is the third arm to say so. Rooting
`null` instead of the recorded pointer is as effective, now at n=24:

| arm (interleaved, n=24) | crashes |
|---|---|
| control | **15/24** |
| grace ≥384, rooting the real blocks | **0/24** |
| grace ≥384, rooting `null` | **0/24** |

So two solid measurements stand side by side and do not reconcile: the block is
genuinely unreferenced in the heap when it dies, *and* what prevents the crash
is reading each newborn block's flags word rather than keeping anything alive.
The most economical reading left is that the crash is a narrow race and touching
those cache lines shifts it — but a bare spin does not, so "narrow race" is a
description, not yet an explanation.

**Next**: the one place not yet measured for this family — the **registers of
the threads suspended at that collection**. `locate_birth_register` already asks
exactly that question and found nothing, but it was written for the `Fiber` case
on the old, now-quiet repro. Re-run it under the fast observer with the ≥384
filter: if the address is in a suspended thread's captured registers, the
register scan is dropping it and the defect is a root-coverage bug after all; if
it is not, the value lives somewhere gcry has never looked.

## Four eliminations, each measured

| arm | crashes / 24 |
|---|---|
| baseline | 6–8 |
| `GCRY_SOUND=1` | 6 |
| `GCRY_INTERIOR=1` | 4 |
| `GCRY_AUTO_LAYOUTS=1` | 6 |
| `ROOT=pool` (explicit root on the `Fiber::StackPool`) | 4 |
| `ROOT=deque` (explicit root on the `Deque`) | 5 |
| `ROOT=buffer` (explicit root on the current buffer, per round) | 7 |
| `GCRY_REALLOC_ROOT_FRESH=1` (never release a root on realloc's *new* block) | 6 |

Nothing moves it. Two of these deserve comment:

- **`ROOT=deque` is the sharp one.** An explicit root marks the object *and*
  pushes it for a payload scan, so `@buffer` is marked at every collection for
  as long as the root exists. The arm was verified live rather than assumed —
  the crash report's own line reads `explicit roots: 0 of 3`, i.e. the root set
  really did hold the deque. The crash rate did not move.
- **`GCRY_REALLOC_ROOT_FRESH`** tested the one window `Heap#realloc` leaves
  open: the *old* block is pinned across the copy, the new one is not, so
  between `allocate` and the caller's `@buffer = …` store the fresh block lives
  only in a register or a stack slot. Rooting it permanently changes nothing.
  The experiment was written, measured and **reverted**.

## And the mark is complete — `GCRY_MARK_AUDIT=1`

After `mark_loop` and before `sweep`, with the world stopped, walk every marked
block and report any base pointer into a **used but unmarked** block: the sweep
is about to free something a live object points at (`src/gcry/mark_audit.cr`).

**15 runs, 6 of them crashing, 30 932 base edges per short run: zero missed
edges.** Not once, in any collection, did a marked object point at a block the
sweep then reclaimed.

That claim is only worth what its positive control is worth, so there are two:

- **Broken on purpose**: stubbing `mark_candidate` so heap edges are not
  followed → `1 missed edge(s) of 235`, naming parent type_id, offset and child.
- **Gated**: `make mark-audit` plants an edge the mark provably does not follow
  — a pointer written into a block's `scan_cap` slack under `GCRY_SCAN_CAPS=1` —
  and requires the audit to name it: **199 missed of 1579 edges**, against
  **0 missed of 1977** on the same workload with the pointer in a real ivar, and
  **0 edges walked** with the knob off.

The slack control needed `GCRY_SCAN_CAPS=1` because the caps are opt-in: with
them off the conservative scan reads the whole payload, slack included, and the
planted edge is not missed at all — measured, 200 of 200 planted children
survived three collections. The first version of the gate did not set the knob
and passed vacuously, which is exactly the failure it exists to prevent.

## What that forces

Combine the three: the block was freed **by the sweep**; at sweep time **no
marked object pointed at it**; at fault time the live deque's `@buffer` **does**
point at it, with `@capacity` matching its size.

The only consistent ordering is that the deque acquired the pointer *after* the
collection that freed the block. So the window is not "an object points at it
and the mark missed the edge" — it is **"nothing points at it yet"**: the block
is live only in a register or a stack slot between being handed out and being
stored into an object, and at that instant a collection reclaimed it.

That relocates the hunt from heap edges to **ambient roots of the allocating
thread**, which is a different subsystem and a different set of suspects
(`mark_root_candidate`'s `base_only`, the type_id gate on stacks, the register
scan of a thread that is *not* the one that triggered the collection, and the
`stack_top` clamp on a running fiber).

**Next**: give a newly handed-out block a birth grace — root every block
`allocate` returns until the end of the next collection — and measure. The
earlier grace-list experiment held the *old* realloc block and failed; this is
the other side of the same window and directly tests "freed before the caller
could store it". If it takes the rate to zero, the defect is ambient-root
coverage of the allocating thread, and the fix is a root-set discipline rather
than a scan change.

## Cost

`GCRY_MARK_AUDIT=1` is O(live heap) inside the pause and off by default. It
reports; it does not fix. `Flags::SWEPT` costs one OR per free.
`mark_audit_edges` / `mark_audit_misses` are on `/gc-stats`, so a run that ends
without a crash still says whether the mark was complete.
