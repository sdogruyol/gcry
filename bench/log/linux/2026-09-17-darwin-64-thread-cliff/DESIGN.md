# Design: the 64-slot STW ceiling, in two halves

Companion to `FINDINGS.md` in this directory. That file establishes the
defects; this one is the plan, and the point of separating them is that the two
halves have very different blast radii.

Read `FINDINGS.md` first. Three corrections to the first reading of the code are
folded in below, because they change the design:

- **Slots are recycled.** `clear_thread_sps` sets `@@stw_claimed` to 0 and
  clears every `@@stw_greg_ok` per STW, and `reset_stw_after_fork` does the same.
  An earlier reading of mine had them accumulating for the life of the process,
  which would have made 64 *distinct* threads enough to lose capture forever.
  That is wrong and no part of this design rests on it.
- **The 64 is structural, and it is not Darwin's.** `MAX_STW_SP_SLOTS` bounds
  four arrays *and* `@@stw_claimed` is an `Atomic(UInt64)` — a 64-bit bitmask.
  `linux_stw.cr` and `windows_stw.cr` have the identical scheme. Capture past
  64 concurrent threads is lost on **every** platform.
- **Linux already names the condition.** `SUSPEND_NO_SLOT = -2`, with the
  comment "Admitted, but with no slot to answer through: the table is full", and
  a deliberate decision to cost that thread its SP clamp rather than the stop.
  So the capture ceiling is known, handled, and — as far as I can find — not
  counted anywhere. Darwin has no equivalent branch at all.

What is Darwin-specific is the **resume** path, and that is the hang.

## Half 1 — the hang: make resume independent of the table

### The defect, exactly

`stop_world_threads` suspends unconditionally and records conditionally:

    kr = LibMach.thread_suspend(port)          # every thread with a port
    ...
    if @@stw_port_count < MAX_STW_SP_SLOTS     # only the first 64
      @@stw_ports[@@stw_port_count] = port

`resume_suspended_ports` walks `0...@@stw_port_count`. Threads past the 64th
are suspended and never resumed.

### The change

Resume by walking the thread list, not the table — the stop already walks it,
and the two walks then cover the same set by construction:

    def self.start_world_threads(current : ::Thread) : Nil
      ::Thread.unsafe_each do |thread|
        next if thread == current
        port = LibC.pthread_mach_thread_np(thread.to_unsafe)
        next if port == 0
        LibMach.thread_resume(port)
        thread.@suspended.set(false)
      end
    end

Symmetry is the argument: the stop suspends *every* non-current thread whose
`pthread_mach_thread_np` is non-zero, so the resume resumes exactly that
predicate. One suspend, one resume, no bound.

`@@stw_ports` and `@@stw_port_count` stay, for one reason only: the error path.
`stop_world_threads` calls `resume_suspended_ports` when a `thread_suspend`
fails mid-loop, and that path must also stop being bounded — it becomes the
same list walk, resuming whatever the loop had already flagged.

### Why not the `@suspended` flag as the record

Tempting — the stop sets `thread.@suspended` to true on success, which is
precisely the set to resume. Rejected because the flag is **Crystal's ivar**,
not gcry's: if Crystal's own suspend protocol ever writes it, gcry's resume
record silently becomes shared state. The port predicate is gcry's own and
cannot be aliased.

### The one hazard, named

A thread created *during* the stop would receive a `thread_resume` it never
earned. Mach's documented behaviour is that `thread_resume` on a thread whose
suspend count is zero returns `KERN_FAILURE` and does nothing — so the stray
call is inert. Two caveats on that: it is documented behaviour I have **not**
confirmed on the platform (no Darwin host here), and if Crystal had suspended
that thread for its own reasons the stray resume would wake it. The thread-birth
machinery (`GCRY_STAGED_WAIT`, `birth_grace.cr`) exists because the list does
move during a stop, so this is not hypothetical and wants a look before landing.

### Proof it works, and that it could fail

The positive control already exists and is already red:
`bench/thread_startup_cost.cr`'s `collect` arm at n=64 and n=100 **TIMEOUT** on
Darwin today, and completes in tens of milliseconds on Linux. If Half 1 is
right, those two cells fill in. That is the whole test, and it needs no new
harness — which is the argument for landing Half 1 first.

Additionally: a counter pair, `stw_threads_suspended` and
`stw_threads_resumed`, incremented in the two loops and asserted **equal** by a
gate. Equality is the invariant the defect violates, and unlike a timing test it
cannot pass by being fast.

## Half 2 — the capture: a table that covers every thread

### What is lost today

`slot_for` returns −1 past 64, so `record_thread_sp` and `record_thread_gregs`
return early. Those threads are suspended with no SP and no registers captured:
the clamped stack scan has no bound for them and `each_thread_greg` yields
nothing. A reference live only in the 65th thread's registers is not a root.
This is the `each_thread_greg` stub shape of v0.19.0 on a new axis, and it is
**cross-platform**.

### Instrument before fix

Nothing counts the −1 today. So, in order:

1. **`stw_capture_no_slot`**, incremented wherever `slot_for` returns −1, on all
   three platforms, exposed on `/gc-stats` beside the other STW counters.
   Reporting only — on a tree where >64 threads is reachable it is *supposed* to
   be non-zero, and a gate asserting zero would be red on master before the fix.
2. A gate asserting it **zero**, landing with the fix rather than before it.
   This is the repo's usual order inverted for a reason: the counter is the
   evidence that the fix was needed and the same counter is the gate afterwards.

### The table

Constraints, in the order they bind:

- **The claim bitmask has to go.** A `UInt64` cannot address more than 64 slots.
  Replace with a per-slot `Atomic(UInt8)` claimed flag; the claim loop is
  already a linear scan, so nothing is lost. A `UInt64[]` word array is the
  alternative and is more code for no gain.
- **It cannot be grown inside the stop.** The tables are read while the world is
  stopped, and `malloc` under a stopped world is how the six-hour hang of
  2026-08-10 happened. Grow at **collection entry, before the first suspend**,
  from the current `Thread` list length plus slack — mutators are still running
  there and the allocator is available.
- **Use `LibC.realloc`, not the gcry heap.** Precedent: `linux_stack.cr`'s
  `grow_stack_bounds_table` doubles `@@sb_ids` / `@@sb_low` / `@@sb_high` with
  `LibC.realloc` for exactly this reason, and returns false rather than raising
  when the allocator refuses — the caller counts a capacity miss. Copy that
  shape, including the miss counter, which is the same counter as (1).

### While it is open, fix the search

`slot_for` is a linear scan over the table called **twice** per thread per STW
(once from `record_thread_sp`, once from `record_thread_gregs`), so the capture
is O(n²) in the pause even below the ceiling. At n=64 that is ~4 096
`pthread_equal` calls per collection; at the thread counts this change is meant
to admit it is the next cliff.

Darwin can drop the search entirely: `stop_world_threads` iterates the threads
itself, so it can hand the slot index to `capture_thread_state` instead of
having it re-derive one from the pthread id. Linux cannot — its handler runs
asynchronously in each thread — so there the scan stays and the growable table
makes it longer. Worth measuring before assuming it is free: `pause_p50` on the
EC4 Kemal arm is the number that would show it.

## Sequencing, and what not to do

1. `stw_capture_no_slot`, reporting only, three platforms.
2. **Half 1** — Darwin resume by list walk, plus the suspended/resumed counter
   pair and its equality gate. Proof: the two TIMEOUT cells in
   `thread_startup_cost` fill in.
3. **Half 2** — growable table, `Atomic(UInt8)` claims, growth at collection
   entry via `LibC.realloc`, Darwin passing the index through, and the gate
   asserting `stw_capture_no_slot == 0` with a >64-thread arm.

Not together. Half 1 is a contained change to a hang on one platform with a
control that is already failing. Half 2 rewrites the slot allocator on the root
scan of all three, and the platform whose STW is most fragile is the one where
the evidence has to come from CI rather than from this host.

And the release question this unblocks: Half 1 is the first change since v0.26.0
that a user would notice — every commit since has been gates, harnesses and
records, with `src/` byte-identical. 0.26.1 is worth cutting when Half 1 lands,
not before.
