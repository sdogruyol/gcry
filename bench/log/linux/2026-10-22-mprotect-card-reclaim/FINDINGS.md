# The mprotect barrier re-armed with the world running (2026-10-22)

Round 1's in-stop audit
(`../2026-10-22-in-stop-sweep-audit/FINDINGS.md`, regression 83) made the
mprotect barrier's SEGV handler hold the stop's suspend signal off, so a
stop never ends with a handler inside. It left one neighbour open, found by
reading: after a lazy sweep, the default, the barrier is re-armed *after*
the stop, with the world running (`collect.cr`, `run_collection_body`'s
lazy branch: `arm_page_barrier_after_major` / `_after_collect`), and the
re-arm's double `clear_mprotect_cards` frees the retired card state at
once, under a handler that may be reading it on another CPU.

Branch `mprotect-card-uaf-039`, from `origin/release-0.39.0` at `32ce703a`.
Local host: QEMU x86-64 guest, 12 vCPU shared with other agents, Crystal
1.21.0.

Result: the hazard is real and is one of four in the same window. Each is
forced deterministically by a research hook with a control arm
(`process_spec/regression/87_mprotect_rearm_running_handler_spec.cr`), and
all four are fixed in `src/gcry/platform/linux_mprotect.cr`.

## The window

A re-arm (`arm_page_barrier_after_collect` → `disarm_mprotect_barrier`,
then `arm_mprotect_on_old_chunks`) does, in order:

1. `mprotect(RW)` every chunk, then clear its protected bits in the old
   cards A (`mprotect_unprotect_range`);
2. `clear_mprotect_cards`: unpublish A (swap to null), retire it, free the
   previously retired state;
3. `mprotect_set_heap_range`: `clear_mprotect_cards` again — the state is
   already null, so this frees A, the one step 2 just retired — then
   allocate and publish the new cards B;
4. `clear_mprotect_dirty_bits` on B;
5. for every old chunk: set its protected bits in B, then `mprotect(READ)`
   (`mprotect_protect_range`).

A handler (`mprotect_fault`) does: read `@@mp_state`, range-check, read the
page's protected bit, set dirty, clear protected, `mprotect(RW)` the page.
It takes no lock (it is a signal handler). With the world running, its
thread can be anywhere in that sequence while the collector runs 1–5, and a
handler can also begin *late*: the kernel delivers the SIGSEGV for a write
taken under A's protection, but the thread can be descheduled before the
handler's first instruction, so the cards it reads may already be B.

Who re-arms with the world running: the lazy branch after every
collection with the mprotect backend armed, and `abort_incremental`
(disarm only, at the top of `collect` / `minor_collect` when a sliced
cycle is open). Every other arm runs inside a stop, where 83 already
guarantees no handler is inside.

## Four hazards, all reproduced

The constructions park the writer thread's handler with a hook from right
after the world restarts (`post_stw_hook :after_start_world`, before the lazy
sweep and the re-arm) until the collection returns, then let it go. A child
checks the generation counter moved after the park, i.e. the re-arm really
ran with the handler inside; if the sweep went into the stop instead it
prints a skip mark and the parent accepts it. Evidence logs: `arms/`.

### 1. Use-after-free of the card state (*held*, `mprotect_fault_hook`)

Parked just after reading `@@mp_state` = A. Step 3 freed A while the handler
held it; when it resumes it reads `nwords` and the bitmap words of A.

- Control (`mprotect_defer_free = false`, the old free): the child observes
  the free under the parked handler (`freed under it 1, retired and kept 0`)
  and leaves before resuming it (`arms/held-control-free.log`), as 82's
  control does. Deterministic: the free is synchronous in the re-arm.
- Fixed: `freed under it 0, retired and kept 1`; after the handler returns,
  the next collection's swap frees it (`mprotect_retired_count` 0).
- What the old code does once resumed depends on what malloc did with A,
  which is why the spec stops at the free. In a scratch copy of the child
  that resumes it with all four knobs off (the code before), the handler
  found the new cards in the freed block and the write was recorded, 20 of
  20 runs, and 20 of 20 again with the span widened by 64 MiB or by 1 GiB
  between the two arms (`arms/held-control-free-resumed-old-code.log`, from
  the scratch copy made while the spec was numbered 85, hence its prefix).
  [INFERENCE] malloc gave the block straight back as B (same size), or
  folded it into the top chunk and carved the larger B from the same
  address: correct by accident, the accident 83's first control runs met.
  Harm needs the block reused for something else or unmapped in between;
  83's construction, which widens the span while the handler is parked,
  dies of it 3 of 3 (below). Under `mallopt(M_MMAP_THRESHOLD, 4096)` with
  two 512 MiB blocks widening the span, 60 of 60 resumed old-code runs were
  still recorded. The free itself is what the spec asserts.

### 2. A forwarded fault that was the barrier's (*held*, same park)

Resumed with A alive, the handler reads A's bits after step 1 cleared them:
protected clear, dirty clear — "not ours". It then restored the previous
SIGSEGV action (Crystal's) and marked the barrier uninstalled. The retried
write hits the page step 5 protected again under B, now with no barrier
handler.

- Control (`mprotect_retry_unclaimed = false`): `Invalid memory access
  (signal 11) at address 0x…` from Crystal's handler, exit 11
  (`arms/held-control-retry.log`).
- Fixed: the unclaimed protection fault is retried once; the retry faults
  under B, is claimed, and the write is in B's dirty bits; the barrier stays
  installed (`arms/held-fixed.log`).

In the wild the same verdict comes from a *late* handler (fault taken under
A, first instruction after step 1). If the page is still writable when the
retried write runs, the fault goes nowhere and the barrier is silently
uninstalled (re-installed at the next arm); if step 5 protected the page
first, the process dies as in the control.

### 3. A stale `mprotect(RW)` after the re-arm (*stale*, `mprotect_claim_hook`)

Parked after claiming the page in A (dirty set, protected cleared), before
its `mprotect(RW)`. Steps 1–5 run; step 5 protects the page under B with its
protected bit set and dirty clear. Resumed, the handler makes the page
writable. B calls it protected and clean, and nothing faults on it again:
the retried write and every later one until the next arm reach no dirty bit.

- Control (`mprotect_revalidate = false`): the current cards do not record
  the page after the writer's write and a second write from the main thread
  (`the current cards record the page: false`,
  `arms/stale-control-recheck.log`).
- Fixed: `true` (`arms/stale-fixed.log`).

Regression 83's construction is this hazard with a stop in place of the
world-running re-arm.

### 4. A claim between the re-arm's protected bit and its `mprotect` (*straggler*)

`mprotect_entry_hook` parks the handler before it reads anything — a late
handler. `mprotect_protect_hook` (collector side, between step 5's bits and
its `mprotect`) lets it go when the re-arm reaches the block and waits for
its write. The handler reads B, finds the protected bit set, claims (dirty
set, protected cleared) and unprotects a page that is still writable. Then
step 5 makes it read-only. Bits: claimed and dirty; page: read-only. The
next writer faults, reads "protected clear, dirty set" — "another thread
took this fault and its `mprotect` will land" — and returns to fault again,
for ever: nothing unprotects the page until a later collection's disarm.

- Control (`mprotect_claim_unprotects = false`): the next writer does not
  finish in 5 s (`the next write went through: false`,
  `arms/straggler-control-unprotect.log`).
- Fixed: it goes through at once (`arms/straggler-fixed.log`).

Locally (default layout) every child ran 30 times: each fixed arm passed
30 of 30 and each control gave its red outcome 30 of 30 (freed under the
handler; `Invalid memory access`, exit 11; write not recorded; writer stuck).

### Three things the constructions needed

Each of these failed an earlier version of the spec, and any hook-driven
test of the mprotect handler needs them too:

- **Hook state outside the GC heap.** A hook that writes a GC-heap object
  from inside the SEGV handler faults if the barrier has protected that page
  since it was last written, and with SIGSEGV blocked in its own handler the
  kernel kills the process without a word (exit 139). A scratch variant
  whose 512 MiB allocations could start a sliced cycle (which re-arms over
  the flags) died that way before the window in 1 of 60 fixed runs and 3 of
  18 control runs; [INFERENCE] that cause, since with the flags' values
  moved to `malloc` memory and no allocation-driven collection (next item)
  the same variant ran 120 of 120 without one.
- **The writer started before the window.** A thread still starting when
  the collection's post-stop section begins can wait for the heap there
  (`@block_other_heap`, single-mutator lazy sweep), in the section where the
  main thread waits for it. The first probe run (`39739343919`, at
  `9e89fddc`) failed the *held* fixed parent 7 times in 60 parent runs
  (6 of 30 on `ubuntu-latest`, 1 of 30 on `ubuntu-24.04-arm`) with "the
  writer's fault never reached the hook"; one of them printed the pin-site
  warning `thread.@scheduler computed slot address … which is not an
  address`, a thread caught before its scheduler was set. Locally, 1 of 20
  scratch runs. The writer now raises a flag from its own thread and the
  constructor waits for it (`800fbbd4`).
- **No allocation-driven collection.** An allocation that opens a sliced
  cycle arms in its own stop, and the next `GC.collect` aborts the cycle and
  disarms with the world running, so the page is writable when the writer
  writes. The children set `gc_threshold` to `UInt64::MAX`.

## The fix (`linux_mprotect.cr`)

All of it is in the handler and the card bookkeeping; the collector's arm
sequence is unchanged and still does not wait for anything.

- **In-flight count.** `mprotect_fault` raises `@@mp_inflight` before it reads
  `@@mp_state` and lowers it after its last access to what it read.
  `clear_mprotect_cards` retires the swapped-out state on a list
  (`MprotectCards#next`) and `reclaim_mprotect_cards` frees the list only when
  the count, read *after* the swap, is zero. Sequentially consistent on both
  sides: a handler that raised the count after that read loads the pointer
  after the swap, so a zero proves nobody holds a retired state. A list the
  re-arm could not free waits for the next swap (the next collection). The
  count is reset in a forked child (`Heap#after_fork_child_reinit` →
  `mprotect_after_fork`): only the forking thread survives.
- **Generation recheck.** `@@mp_gen` is bumped after every swap and every
  dirty clear — each precedes the collector protecting pages anew. The
  handler reads it before the card state; after its `mprotect(RW)` it reads
  it again and, if it moved, ORs the page's dirty bit into the current
  cards (`mprotect_recheck`). A state the handler read stale implies a moved
  generation because the collector bumps after the swap. A re-protect after
  the recheck lands after the handler's `mprotect`, so it leaves the page
  read-only. The current cards cannot be freed under the recheck: the
  handler is still counted.
- **Retry once.** An unclaimed `SEGV_ACCERR` is retried once before the
  barrier forwards it (`mprotect_unclaimed`), keyed by a thread-local
  (address, generation): the same fault again in the same generation is not
  the barrier's. A late handler's retry either succeeds (the page is
  writable) or faults onto the re-armed protection, which is claimable —
  step 5 sets the bit before the `mprotect`. A foreign protection fault
  costs one extra delivery. `SEGV_MAPERR` is forwarded at once as before.
- **Claimers unprotect.** A handler that finds the page already claimed
  (protected clear, dirty set, or lost the clear race) now makes the page
  writable itself instead of trusting the claimer's `mprotect`. Idempotent;
  costs one extra `mprotect` only when two faults on one page race.
- While rewriting the range check: `((addr - base) // PAGE).to_i32` raised
  `OverflowError` — an allocation, inside the signal handler — for an
  address more than 8 TiB above the card base (`2^31` 4 KiB pages). The
  distance is now compared with the range before it is narrowed.

83's suspend mask stays: a stop with no handler inside is the simpler
guarantee for the in-stop arm. With this fix the mask alone no longer
decides 83's control, because a frozen handler is also rescued by the
deferred free and the retry. A scratch copy of 83's control child with only
the mask off still saw a stop end inside the handler, and then recorded the
write, 3 of 3 (`expected false, got true`). With the four new knobs off as
well it died with SIGSEGV inside the handler, exit 139, 3 of 3, as it always
had. So 83's control child now turns the four knobs off too, which is the
code before both fixes.

## Reach

The mprotect backend is chosen when soft-dirty does not track writes, or
with `GCRY_MPROTECT_BARRIER=1`, and is armed only with incremental marking
(`GCRY_INCREMENTAL=1`) or a nursery (`GCRY_NURSERY`, header layout). Both
are off by default on every platform (`gc_override.cr`), so no default
configuration installs the handler. On aarch64 Linux it is the backend
those opt-ins get: probe run `39739343919`, `ubuntu-24.04-arm` (kernel
6.17.0-1022-azure, no `CONFIG_MEM_SOFT_DIRTY`), `GCRY_INCREMENTAL=1` armed
`mprotect`; on `ubuntu-latest` (`CONFIG_MEM_SOFT_DIRTY=y`) it armed
`soft_dirty`; without the variable neither armed anything. The lazy branch
is the default sweep with TLAB off, so with either opt-in on the mprotect
backend every collection re-arms with the world running.

Default path: untouched except one atomic store in a forked child's reset
(`collect_stw.cr`), which no benchmark reaches; no perf-ab run.

## Not changed, noted

- [INFERENCE] The cards armed after a lazy sweep start at the re-arm, not at
  the stop: writes between `start_world` and the re-arm were recorded in A
  and are dropped with it. No consumer needs them today: the minor
  collection walks every old object for nursery pointers whatever the cards
  say (`scan_old_for_nursery_pointers`), and an incremental cycle arms its
  own cards inside the stop that begins it (`begin_incremental`). A consumer
  that trusted lazy-arm cards alone would need A's dirty bits carried over.
- [INFERENCE] The handler is installed without `SA_ONSTACK`, replacing
  Crystal's, which has an alternate stack: under the mprotect barrier a
  stack overflow on a guard page cannot run any handler and dies with a bare
  SIGSEGV instead of Crystal's "Stack overflow" message. Not tested.
- [INFERENCE] `GCRY_UNMAP_GUARD=1` and `GCRY_RELEASE_QUARANTINE` release a
  chunk with `PROT_NONE`, but nothing clears the chunk's bits in the cards
  (`mprotect_unprotect_range` runs only in the disarm). A stray write to such
  a page whose protected bit is set is claimed and unprotected, which
  defeats the guard. With the dirty bit set instead, the old code looped on
  the fault; now it unprotects. Diagnostic modes only; the release should
  clear the range's bits.
- Regression 84's *publish-lazy* fixed child (`GCRY_BITMAP_ALLOC=0`,
  `-Dgcry_block_headers`) failed one local header-freelist `process_spec` run
  here, at `shared.should be_false`. Unrelated to this branch: it fails on
  `origin/release-0.39.0` at `32ce703a` 4 of 40 runs (2 of 40 on this
  branch), and the barrier is not armed in it. Reported to the release
  owner.

## CI probe

`probe/mprotect-card-reclaim` (deleted), push-triggered, `ubuntu-24.04-arm`
and `ubuntu-latest`. Each built regressions 83 and 87 (numbered 85 at the
time; renumbered to 87 before the final push, no other change) together on
the three layouts CI runs `process_spec` on, ran every child of 87 once with
its output, then ran the pair 10 times per layout:

- `39739343919` at `9e89fddc`. Every child gave its expected outcome on
  every layout and runner. The *held* fixed parent failed 7 of 60 runs on
  the writer-startup race described above, and the run failed.
- `39740286009` at `800fbbd4`: success. 30 of 30 runs on each runner, 18
  examples and 0 failures each; every child on every layout and runner gave
  its expected outcome (fixed: recorded or went through; controls: freed
  under the handler, `Invalid memory access`, write lost, writer stuck).

## Checks

At `800fbbd4`, locally, each holding the shared lock in turn, bounded by
`bench/run_bounded.sh`:

| Check | Result |
|---|---|
| `crystal tool format --check src spec process_spec bench samples` | pass |
| `make lint` | pass |
| `crystal spec -Dgc_none spec/all_specs.cr` | 296 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers spec/all_specs.cr` | 318 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 266 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 267 examples, 0 failures |
| `GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 267 examples, 1 failure (84 *publish-lazy* fixed, above); rerun: 267 examples, 0 failures |
| `make windows-typecheck` | pass |
| `crystal build --no-codegen -Dgc_none --cross-compile --target aarch64-apple-darwin samples/hello.cr` | pass |

After the renumbering to 87, which renames the file and its identifiers and
changes comment references and nothing else: the format check passes; 87
alone on the default layout gives 14 examples, 0 failures, with every child
as before (`arms/` refreshed); and 83 with 87 gives 18 examples, 0 failures
on the header layout and on header with `GCRY_BITMAP_ALLOC=0`.

After review (`agent://MprotectReview`, no blockers), two fixes:

- The handler's thread-local "last unclaimed fault" address is kept
  complemented. Thread-local storage is a conservative root, so the raw
  heap address could have pinned an object for the life of the thread.
- 83 and 87 size their block at least two pages and target the first page
  boundary past its start. Rounding the middle of a 64 KiB block down lands
  before the block on a 64 KiB-page arm64 kernel, so the writes would have
  gone to a neighbour.

After them, 83 with 87 gives 18 examples, 0 failures on each of the default,
header and header + `GCRY_BITMAP_ALLOC=0` layouts. The format check,
`make lint`, `make windows-typecheck` and the darwin cross-compile also pass.
