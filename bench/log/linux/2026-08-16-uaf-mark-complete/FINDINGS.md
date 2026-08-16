# The fiber-creation use-after-free: the sweep freed it, and the mark was complete

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
